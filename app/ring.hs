{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE StaticPointers     #-}
{-# OPTIONS_GHC -fno-warn-orphans -w #-}

module Main where

import Control.Concurrent (threadDelay)
import Control.Distributed.Closure (Closure)
import Control.Monad.IO.Class (liftIO)
import Data.Binary (Get, get )
import qualified Data.HashMap.Strict as HM
import qualified Data.List as L
import qualified Data.Text as T
import Network.Simple.TCP (type HostName, type ServiceName)
import System.Environment (getArgs)
import UnliftIO.Async (async,wait)
--
import Control.Distributed.Playground.Comm ( M, NodeName(..), SocketPool(..), getPool, logText )
import Control.Distributed.Playground.MasterSlave (master,slave)
import Control.Distributed.Playground.Request ( Request
                                              , SomeRequest(..)
                                              , StaticSomeRequest(..)
                                              , requestToM )

instance StaticSomeRequest (Request () Int) where
  staticSomeRequest _ = static (SomeRequest <$> (get :: Get (Request () Int)))

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

testAction :: M ()
testAction = do
  logText $ "testAction called"



-- NOTE: () -> M () cause the following error:
-- Network.Socket.recvBuf: invalid argument (non-positive length)
-- TODO: investigate this.
mkclosure1 :: M (Closure (() -> M Int))
mkclosure1 = do
  let c = static (\() -> testAction >> pure 0)
  pure c

-- | main process
process :: IO ()
process =
  master nodeList $ do
    liftIO $ threadDelay 1000000
    SocketPool sockMap <- getPool
    logText (T.pack (show $ map (\(k,(_,v)) -> (k,v)) $ HM.toList sockMap))
    a1 <-
      async $
        mkclosure1 >>= \clsr -> requestToM (NodeName "slave1") clsr [()]
    r1 <- wait a1
    -- logText (T.pack (show r1))
    logText "finished"
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
