module Control.Distributed.Playground.P2P where

import Data.Word (Word32)
--
import Control.Distributed.Playground.Comm (M,SPort,RPort,NodeName)

data P2PChanInfo = P2PChanInfo {
    p2pChanId :: Word32
  , p2pSender :: NodeName
  , p2pReceiver :: NodeName
  }


data SendP2PProto a = SendP2PProto {
    sprotoChanId :: Word32
  }

data RecvP2PProto a = RecvP2PProto {
    rprotoChanId :: Word32
  }

data SendP2P a = SendP2P {
    sp2pChanId :: Word32
  , sp2pPort :: SPort a
  }

data RecvP2P a = RecvP2P {
    rp2pChanId :: Word32
  , rp2pPort :: RPort a
  }



createSendP2P :: SendP2PProto a -> M (SendP2P a)
createSendP2P = undefined

createRecvP2P :: RecvP2PProto a -> M (RecvP2P a)
createRecvP2P = undefined
