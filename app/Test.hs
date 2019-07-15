{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StaticPointers    #-}
{-# LANGUAGE TemplateHaskell   #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}
module Test where

import Control.Concurrent (threadDelay)
import Control.Distributed.Closure (Closure,cpure,closureDict)
import Control.Distributed.Closure.TH (withStatic)
import Control.Monad.IO.Class (liftIO)
import Data.Binary (Binary, Get, get )
import Data.Functor.Static (staticMap)
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import UnliftIO.Async (async,wait)
--
import Control.Distributed.Playground.Comm    ( M
                                              , NodeName(..)
                                              , SocketPool(..)
                                              , getPool
                                              , logText
                                              , receiveChan
                                              , sendChan
                                              )
import Control.Distributed.Playground.P2P     ( RecvP2PProto
                                              , SendP2PProto
                                              , RecvP2P(..)
                                              , SendP2P(..)
                                              , createP2P
                                              , newP2P
                                              , getSendP2P
                                              )
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


testAction :: M ()
testAction = do
  logText $ "testAction called"
  SocketPool sockMap <- getPool
  logText (T.pack (show $ map (\(k,(_,v)) -> (k,v)) $ HM.toList sockMap))

testAction2 :: SendP2PProto Int -> M ()
testAction2 spp = do
  logText $ "testAction2 called"
  logText $ T.pack (show spp)
  sp2p <- getSendP2P spp
  logText $ "sp2p received"
  sendChan (sp2pPort sp2p) 514
  logText $ "514 has been sent"
  pure ()

testAction3 :: RecvP2PProto Int -> M ()
testAction3 rpp = do
  logText $ "testAction3 called"
  logText $ T.pack (show rpp)
  rp2p <- createP2P rpp
  logText $ "receive p2p port is created"
  result <- receiveChan (rp2pPort rp2p)
  logText $ "received from p2p: " <> T.pack (show result)

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
process :: M ()
process = do
  liftIO $ threadDelay 1000000
  SocketPool sockMap <- getPool
  logText (T.pack (show $ map (\(k,(_,v)) -> (k,v)) $ HM.toList sockMap))

  (sp2p,rp2p) <- newP2P

  a1 <- async $ requestToM (NodeName "slave1") closure1 [()]
  a3 <- async $ requestToM (NodeName "slave3") closure1 [()]

  _r1 <- wait a1
  _r3 <- wait a3

  a1' <-async $ requestToM (NodeName "slave1") (closure2 sp2p) [()]
  a3' <-async $ requestToM (NodeName "slave3") (closure3 rp2p) [()]

  _r1' <- wait a1'
  _r3' <- wait a3'

  -- liftIO $ threadDelay 5000000
  logText "finished"
  pure ()
