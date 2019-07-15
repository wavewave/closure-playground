{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module Control.Distributed.Playground.P2P where

import Data.Binary (Binary)
import Data.Typeable (Typeable)
import Data.Word (Word32)
import GHC.Generics (Generic)
--
import Control.Distributed.Playground.Comm ( M
                                           , SPort(..)
                                           , RPort
                                           , NodeName(..)
                                           , newChan
                                           , receiveChan
                                           , sendChan
                                           )
import Control.Distributed.Playground.Request (peerReqChanId)



data P2PChanInfo = P2PChanInfo {
    p2pChanId :: Word32
  , p2pSender :: NodeName
  , p2pReceiver :: NodeName
  }

data SendP2PProto a = SendP2PProto {
    sprotoChanId :: Word32
  }
  deriving (Generic,Typeable,Show)

instance Binary (SendP2PProto a)

data RecvP2PProto a = RecvP2PProto {
    rprotoChanId :: Word32
  }
  deriving (Generic,Typeable,Show)

instance Binary (RecvP2PProto a)

newP2P :: M (SendP2PProto a, RecvP2PProto a)
newP2P = pure (SendP2PProto 1234, RecvP2PProto 1234)

data SendP2P a = SendP2P {
    sp2pChanId :: Word32
  , sp2pPort :: SPort a
  } deriving (Generic)

instance Binary (SendP2P a)

data RecvP2P a = RecvP2P {
    rp2pChanId :: Word32
  , rp2pPort :: RPort a
  }

data P2PBrokerRequest = AddP2PChannel (SendP2P Int)
                      | GetP2PChannel (SendP2PProto Int) (SPort (SendP2P Int))
                      deriving (Generic)

instance Binary P2PBrokerRequest


getSendP2P :: SendP2PProto Int -> M (SendP2P Int)
getSendP2P spp = do
  (sp,rp) <- newChan @(SendP2P Int)
  sendChan (SPort (NodeName "master") peerReqChanId) (GetP2PChannel spp sp)
  sp2p <- receiveChan rp
  pure $! sp2p

createP2P :: RecvP2PProto Int -> M (RecvP2P Int)
createP2P rpp = do
  (sp,rp) <- newChan
  let sp2p = SendP2P (rprotoChanId rpp) sp
  sendChan (SPort (NodeName "master") peerReqChanId) (AddP2PChannel sp2p)
  pure $! RecvP2P (rprotoChanId rpp) rp
