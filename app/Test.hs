{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StaticPointers    #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}
module Test where

import Control.Concurrent             ( threadDelay )
import Control.Distributed.Closure    ( Closure
                                      , Dict(..)
                                      , Static(..)
                                      , cpure
                                      , closure
                                      , closureDict
                                      )
import Control.Monad                  ( replicateM )
import Control.Monad.IO.Class         ( liftIO )
import Data.Binary                    ( Binary, Get, get )
import Data.Foldable                  ( traverse_ )
import Data.Functor.Static            ( staticMap )
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import Data.Traversable               ( for )
import Data.Typeable                  ( Typeable )
import GHC.Generics                   ( Generic )
import GHC.StaticPtr                  ( StaticPtr )
import UnliftIO.Async                 ( async, wait )
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

instance StaticSomeRequest (Request () ()) where
  staticSomeRequest _ = static (SomeRequest <$> (get :: Get (Request () ())))

instance StaticSomeRequest (Request () Int) where
  staticSomeRequest _ = static (SomeRequest <$> (get :: Get (Request () Int)))


newtype SProtoInt = SProtoInt (SendP2PProto Int)
                  deriving (Generic, Typeable)

instance Binary SProtoInt

instance Static (Binary SProtoInt) where
  closureDict = closure (static f :: StaticPtr (Dict (Binary SProtoInt)))
    where
      f :: Dict (Binary SProtoInt)
      f = Dict

instance Static (Typeable SProtoInt) where
  closureDict = closure (static f :: StaticPtr (Dict (Typeable SProtoInt)))
    where
      f :: Dict (Typeable SProtoInt)
      f = Dict


newtype RProtoInt = RProtoInt (RecvP2PProto Int)
                  deriving (Generic, Typeable)

instance Binary RProtoInt

instance Static (Binary RProtoInt) where
  closureDict = closure (static f :: StaticPtr (Dict (Binary RProtoInt)))
    where
      f :: Dict (Binary RProtoInt)
      f = Dict

instance Static (Typeable RProtoInt) where
  closureDict = closure (static f :: StaticPtr (Dict (Typeable RProtoInt)))
    where
      f :: Dict (Typeable RProtoInt)
      f = Dict

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

closure1 :: Closure (() -> M ())
closure1 = static (\() -> testAction)

closure2 :: SendP2PProto Int -> Closure (() -> M ())
closure2 sp2p =
  static (\(SProtoInt sp) () -> testAction2 sp)
  `staticMap` cpure closureDict (SProtoInt sp2p)

closure3 :: RecvP2PProto Int -> Closure (() -> M ())
closure3 rp2p = do
  static (\(RProtoInt rp) () -> testAction3 rp)
  `staticMap` cpure closureDict (RProtoInt rp2p)


-- | a test.
test1 :: M ()
test1 = do
  -- TODO: this must not be needed. Examine and remove it.
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

  logText "finished"
  pure ()


--------------------------------
-- more nontrivial relay test --
--------------------------------

initPass :: SendP2PProto Int -> M ()
initPass toNextP = do
  logText $ "initPass called"
  toNext <- getSendP2P toNextP
  let baton = 0
  logText $ "start a baton with value: " <> T.pack (show baton)
  sendChan (sp2pPort toNext) baton

finalPass :: RecvP2PProto Int -> M Int
finalPass fromPrevP = do
  logText $ "finalPass called"
  fromPrev <- createP2P fromPrevP
  baton <- receiveChan (rp2pPort fromPrev)
  logText $ "got a baton with value: " <> T.pack (show baton)
  pure baton

relayer :: RecvP2PProto Int -> SendP2PProto Int -> M ()
relayer fromPrevP toNextP = do
  logText $ "relayer called"
  fromPrev <- createP2P fromPrevP
  toNext <- getSendP2P toNextP
  baton <- receiveChan (rp2pPort fromPrev)
  logText $ "got a baton with value: " <> T.pack (show baton)
  logText $ "send a baton after increasing by one"
  sendChan (sp2pPort toNext) (baton+1)


clsr_initPass :: SendP2PProto Int -> Closure (() -> M ())
clsr_initPass toNextP =
  static (\(SProtoInt sp) () -> initPass sp)
  `staticMap` cpure closureDict (SProtoInt toNextP)

clsr_finalPass :: RecvP2PProto Int -> Closure (() -> M Int)
clsr_finalPass fromPrevP =
  static (\(RProtoInt rp) () -> finalPass rp)
  `staticMap` cpure closureDict (RProtoInt fromPrevP)

clsr_relayer :: RecvP2PProto Int -> SendP2PProto Int -> Closure (() -> M ())
clsr_relayer fromPrevP toNextP =
  static (\(RProtoInt rp) (SProtoInt sp) () -> relayer rp sp)
  `staticMap` cpure closureDict (RProtoInt fromPrevP)
  `staticMap` cpure closureDict (SProtoInt toNextP)

numPlayer :: Int
numPlayer = 4

nthSlave :: Int -> NodeName
nthSlave n = NodeName $ "slave" <> (T.pack (show n))

initSlave :: NodeName
initSlave = nthSlave 0

lastSlave :: NodeName
lastSlave = nthSlave numPlayer


-- | relaying test
relay :: M ()
relay = do
  liftIO $ threadDelay 1000000

  chs <- replicateM numPlayer newP2P
  let sps = map fst chs -- send ports
      rps = map snd chs -- receive ports
      sp0 = head sps
      rpn = last rps
  let pairs = zip rps (tail sps)  -- (r_i,s_(i+1))
      nodes = map nthSlave [1..numPlayer-1]
  as <- for (zip pairs nodes) $ \((rpp,spp),node) -> do
          a <- async $ requestToM node (clsr_relayer rpp spp) [()]
          pure a
  a0 <- async $ requestToM initSlave (clsr_initPass sp0) [()]
  an <- async $ requestToM lastSlave (clsr_finalPass rpn) [()]

  _ <- wait a0
  traverse_ wait as
  rn <- wait an
  liftIO $ print rn
