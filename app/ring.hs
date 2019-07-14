{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent (threadDelay)
import Control.Monad.IO.Class (liftIO)
import qualified Data.HashMap.Strict as HM
import qualified Data.List as L
import qualified Data.Text as T
import Network.Simple.TCP (type HostName, type ServiceName)
import System.Environment (getArgs)
--
import Control.Distributed.Playground.Comm ( NodeName(..), SocketPool(..), getPool )
import Control.Distributed.Playground.MasterSlave (master,slave)


{-
-- prototype pseudocode
process :: IO ()
process =
  master nodeList $ do
    chs <- replicateM 10 mkChan
    let sps = map fst chs -- send ports
        rps = map snd chs -- receive ports
        sp0 = head sps
        rpn = last rps
    let pairs = zip (tail sps) rps   -- (s_(i+1), r_i)
    for_ pairs $ \(s',r) -> do
      action s r'

    send sp0 "1234"
    r <- recv rpn
    print r


action s r' = do
  msg <- recv r'
  send s msg
-}

nodeList :: [(NodeName,(HostName,ServiceName))]
nodeList = [ (NodeName "slave1", ("127.0.0.1", "4929"))
           , (NodeName "slave2", ("127.0.0.1", "4939"))
           , (NodeName "slave3", ("127.0.0.1", "4949"))
           ]

process :: IO ()
process =
  master nodeList $ do
    liftIO $ threadDelay 5000000
    SocketPool sockMap <- getPool -- liftIO . readTVarIO =<< chSockets <$> ask
    liftIO $ print $ map (\(k,(_,v)) -> (k,v)) $ HM.toList sockMap
    pure ()

main :: IO ()
main = do
  a0:_ <- getArgs
  case a0 of
    "master" -> process
    _ -> let name = NodeName (T.pack a0)
         in case L.lookup name nodeList of
              Just (hostName,serviceName) -> slave name hostName serviceName
              Nothing -> error $ "cannot find " ++ a0
