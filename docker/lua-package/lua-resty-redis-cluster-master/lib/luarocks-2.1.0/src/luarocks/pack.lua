
--- Module implementing the LuaRocks "pack" command.
-- Creates a rock, packing sources or binaries.
module("luarocks.pack", package.seeall)

local path = require("luarocks.path")
local repos = require("luarocks.repos")
local fetch = require("luarocks.fetch")
local fs = require("luarocks.fs")
local cfg = require("luarocks.cfg")
local util = require("luarocks.util")
local dir = require("luarocks.dir")
local manif = require("luarocks.manif")
local search = require("luarocks.search")

help_summary = "Create a rock, packing sources or binaries."
help_arguments = "{<rockspec>|<name> [<version>]}"
help = [[
Argument may be a rockspec file, for creating a source rock,
or the name of an installed package, for creating a binary rock.
In the latter case, the app version may be given as a second
argument.
]]

--- Create a source rock.
-- Packages a rockspec and its required source files in a rock
-- file with the .src.rock extension, which can later be built and
-- installed with the "build" command.
-- @param rockspec_file string: An URL or pathname for a rockspec file.
-- @return string or (nil, string): The filename of the resulting
-- .src.rock file; or nil and an error message.
local function pack_source_rock(rockspec_file)
   assert(type(rockspec_file) == "string")

   local rockspec, err = fetch.load_rockspec(rockspec_file)
   if err then
      return nil, "Error loading rockspec: "..err
   end
   rockspec_file = rockspec.local_filename

   local name_version = rockspec.name .. "-" .. rockspec.version
   local rock_file = fs.absolute_name(name_version .. ".src.rock")

   local source_file, source_dir = fetch.fetch_sources(rockspec, false)
   if not source_file then
      return nil, source_dir
   end
   fs.change_dir(source_dir)

   fs.delete(rock_file)
   fs.copy(rockspec_file, source_dir)
   if not fs.zip(rock_file, dir.base_name(rockspec_file), dir.base_name(source_file)) then
      return nil, "Failed packing "..rock_file
   end
   fs.pop_dir()

   return rock_file
end

local function copy_back_files(name, version, file_tree, deploy_dir, pack_dir)
   fs.make_dir(pack_dir)
   for file, sub in pairs(file_tree) do
      local source = dir.path(deploy_dir, file)
      local target = dir.path(pack_dir, file)
      if type(sub) == "table" then
         local ok, err = copy_back_files(name, version, sub, source, target)
      else
         local versioned = path.versioned_name(source, deploy_dir, name, version)
         if fs.exists(versioned) then
            fs.copy(versioned, target)
         else
            fs.copy(source, target)
         end
      end
   end
   return true
end

-- @param name string: Name of package to pack.
-- @param version string or nil: A version number may also be passed.
-- @return string or (nil, string): The filename of the resulting
-- .src.rock file; or nil and an error message.
local function do_pack_binary_rock(name, version)
   assert(type(name) == "string")
   assert(type(version) == "string" or not version)

   local query = search.make_query(name, version)
   query.exact_name = true
   local results = {}
   
   search.manifest_search(results, cfg.rocks_dir, query)
   
   if not next(results) then
      return nil, "'"..name.."' does not seem to be an installed rock."
   end
   
   local versions = results[name]
   
   if not version then
      local first = next(versions)
      if next(versions, first) then
         return nil, "Please specify which version of '"..name.."' to pack."
      end
      version = first
   end
   if not version:match("[^-]+%-%d+") then
      return nil, "Expected version "..version.." in version-revision format."
   end
   
   local info = versions[version][1]
   
   local root = path.root_dir(info.repo)
   local prefix = path.install_dir(name, version, root)
   if not fs.exists(prefix) then
      return nil, "'"..name.." "..version.."' does not seem to be an installed rock."
   end
   
   local rock_manifest = manif.load_rock_manifest(name, version, root)
   if not rock_manifest then
      return nil, "rock_manifest file not found for "..name.." "..version.." - not a LuaRocks 2 tree?"
   end

   local name_version = name .. "-" .. version
   local rock_file = fs.absolute_name(name_version .. "."..cfg.arch..".rock")
   
   local temp_dir = fs.make_temp_dir("pack")
   fs.copy_contents(prefix, temp_dir)

   local is_binary = false
   if rock_manifest.lib then
      copy_back_files(name, version, rock_manifest.lib, path.deploy_lib_dir(root), dir.path(temp_dir, "lib"))
      is_binary = true
   end
   if rock_manifest.lua then
      copy_back_files(name, version, rock_manifest.lua, path.deploy_lua_dir(root), dir.path(temp_dir, "lua"))
   end
   
   fs.change_dir(temp_dir)
   if not is_binary and not repos.has_binaries(name, version) then
      rock_file = rock_file:gsub("%."..cfg.arch:gsub("%-","%%-").."%.", ".all.")
   end
   fs.delete(rock_file)
   if not fs.zip(rock_file, unpack(fs.list_dir())) then
      return nil, "Failed packing "..rock_file
   end
   fs.pop_dir()
   fs.delete(temp_dir)
   return rock_file
end

function pack_binary_rock(name, version, cmd, ...)

   -- The --pack-binary-rock option for "luarocks build" basically performs
   -- "luarocks build" on a temporary tree and then "luarocks pack". The
   -- alternative would require refactoring parts of luarocks.build and
   -- luarocks.pack, which would save a few file operations: the idea would be
   -- to shave off the final deploy steps from the build phase and the initial
   -- collect steps from the pack phase.

   local temp_dir = fs.make_temp_dir("luarocks-build-pack-"..dir.base_name(name))
   if not temp_dir then
      return nil, "Failed creating temporary directory."
   end
   util.schedule_function(fs.delete, temp_dir)

   path.use_tree(temp_dir)
   local ok, err = cmd(...)
   if not ok then
      return nil, err
   end
   local rname, rversion = path.parse_name(name)
   if not rname then
      rname, rversion = name, version
   end
   return do_pack_binary_rock(rname, rversion)
end

--- Driver function for the "pack" command.
-- @param arg string:  may be a rockspec file, for creating a source rock,
-- or the name of an installed package, for creating a binary rock.
-- @param version string or nil: if the name of a package is given, a
-- version may also be passed.
-- @return boolean or (nil, string): true if successful or nil followed
-- by an error message.
function run(...)
   local flags, arg, version = util.parse_flags(...)
   assert(type(version) == "string" or not version)
   if type(arg) ~= "string" then
      return nil, "Argument missing. "..util.see_help("pack")
   end

   local file, err
   if arg:match(".*%.rockspec") then
      file, err = pack_source_rock(arg)
   else
      file, err = do_pack_binary_rock(arg, version)
   end
   if err then
      return nil, err
   else
      util.printout("Packed: "..file)
      return true
   end
end
