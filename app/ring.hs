{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TemplateHaskell     #-}

module Main where

import qualified Data.List as L
import qualified Data.Text as T
import Network.Simple.TCP (type HostName, type ServiceName)
import System.Environment (getArgs)
--
import Control.Distributed.Playground.Comm ( NodeName(..) )
import Control.Distributed.Playground.MasterSlave (master,slave)
--
import Test (relay) -- (test1)

nodeList :: [(NodeName,(HostName,ServiceName))]
nodeList = [ (NodeName "slave0", ("127.0.0.1", "4219"))
           , (NodeName "slave1", ("127.0.0.1", "4929"))
           , (NodeName "slave2", ("127.0.0.1", "4939"))
           , (NodeName "slave3", ("127.0.0.1", "4949"))
           , (NodeName "slave4", ("127.0.0.1", "4959"))
           ]


-- | main
main :: IO ()
main = do
  a0:_ <- getArgs
  case a0 of
    "master" -> master nodeList relay -- test1
    _ -> let name = NodeName (T.pack a0)
         in case L.lookup name nodeList of
              Just (hostName,serviceName) -> slave name hostName serviceName
              Nothing -> error $ "cannot find " ++ a0
