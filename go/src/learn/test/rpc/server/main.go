package main

import (
	"github.com/gpmgo/gopm/modules/log"
	"gopkg.in/olivere/elastic.v3"
	"learn/crawler_distributed/rpcsupport"
)

const profileDatabase = "dating_profile"

func main() {

	serverRpc(":1234", profileDatabase)
}

func serverRpc(host, index string) error {

	client, err := elastic.NewClient(
		elastic.SetSniff(false))

	if err != nil {
		log.Fatal("start elasticSearch fail %v", err)
	}

	itemSaverService := rpcsupport.ItemSaverService{
		Client: client,
		Index:  index,
	}

	return rpcsupport.RpcServer(host, itemSaverService)

}
