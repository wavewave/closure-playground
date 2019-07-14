{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE StaticPointers     #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-orphans -w #-}

module Main where

import Control.Concurrent (threadDelay)
import Control.Distributed.Closure (Closure,cpure,closureDict)
import Control.Distributed.Closure.TH (withStatic)
import Control.Monad.IO.Class (liftIO)
import Data.Binary (Binary, Get, get )
import Data.Functor.Static (staticMap)
import qualified Data.HashMap.Strict as HM
import qualified Data.List as L
import qualified Data.Text as T
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Network.Simple.TCP (type HostName, type ServiceName)
import System.Environment (getArgs)
import UnliftIO.Async (async,wait)
--
import Control.Distributed.Playground.Comm ( M, NodeName(..), SocketPool(..), getPool, logText )
import Control.Distributed.Playground.MasterSlave (master,slave)
import Control.Distributed.Playground.P2P (SendP2PProto, RecvP2PProto, createP2P, newP2P)
import Control.Distributed.Playground.Request ( Request
                                              , SomeRequest(..)
                                              , StaticSomeRequest(..)
                                              , requestToM
                                              )

instance StaticSomeRequest (Request () Int) where
  staticSomeRequest _ = static (SomeRequest <$> (get :: Get (Request () Int)))


newtype SProtoInt = SProtoInt (SendP2PProto Int)
                  deriving (Generic, Typeable)

withStatic [d|
  instance Binary SProtoInt
  instance Typeable SProtoInt
  |]

newtype RProtoInt = RProtoInt (RecvP2PProto Int)
                  deriving (Generic, Typeable)

withStatic [d|
  instance Binary RProtoInt
  instance Typeable RProtoInt
  |]



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
  SocketPool sockMap <- getPool
  logText (T.pack (show $ map (\(k,(_,v)) -> (k,v)) $ HM.toList sockMap))

testAction2 :: SendP2PProto Int -> M ()
testAction2 s = do
  logText $ "testAction2 called"
  logText $ T.pack (show s)

testAction3 :: RecvP2PProto Int -> M ()
testAction3 rpp = do
  logText $ "testAction3 called"
  logText $ T.pack (show rpp)
  rp <- createP2P rpp
  logText $ "receive p2p port is created"

-- NOTE: `() -> M ()` cause the following error:
-- "Network.Socket.recvBuf: invalid argument (non-positive length)"
-- TODO: investigate this.
closure1 :: Closure (() -> M Int)
closure1 = static (\() -> testAction >> pure 0)

closure2 :: SendP2PProto Int -> Closure (() -> M Int)
closure2 sp2p =
  static (\(SProtoInt sp) () -> testAction2 sp >> pure 0)
  `staticMap` cpure closureDict (SProtoInt sp2p)

closure3 :: RecvP2PProto Int -> Closure (() -> M Int)
closure3 rp2p = do
  static (\(RProtoInt rp) () -> testAction3 rp >> pure 0)
  `staticMap` cpure closureDict (RProtoInt rp2p)

-- | main process
process :: IO ()
process =
  master nodeList $ do
    liftIO $ threadDelay 1000000
    SocketPool sockMap <- getPool
    logText (T.pack (show $ map (\(k,(_,v)) -> (k,v)) $ HM.toList sockMap))

    (sp2p,rp2p) <- newP2P
    {-
    a1 <- async $ requestToM (NodeName "slave1") closure1 [()]
    a3 <- async $ requestToM (NodeName "slave3") closure1 [()]

    r1 <- wait a1
    r3 <- wait a3
    -}
    a1' <-async $ requestToM (NodeName "slave1") (closure2 sp2p) [()]
    a3' <-async $ requestToM (NodeName "slave3") (closure3 rp2p) [()]

    r1' <- wait a1'
    r3' <- wait a3'

    liftIO $ threadDelay 5000000
    logText "finished"
    pure ()

-- | main
main :: IO ()
main = do
  a0:_ <- getArgs
  case a0 of
    "master" -> process
    _ -> let name = NodeName (T.pack a0)
         in case L.lookup name nodeList of
              Just (hostName,serviceName) -> slave name hostName serviceName
              Nothing -> error $ "cannot find " ++ a0
