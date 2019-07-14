module Control.Distributed.Playground.P2P where

import Control.Concurrent.STM (TChan)
import Data.Word (Word32)
--
import Control.Distributed.Playground.Comm (M)

data SendP2PProto a = SendP2PProto {
    sprotoChanId :: Word32
  }

data RecvP2PProto a = RecvP2PProto {
    rprotoChanId :: Word32
  }

data SendP2P a = SendP2P {
    sp2pQueue :: TChan a
  , sp2pChanId :: Word32
  }

data RecvP2P a = RecvP2P {
    rp2pQueue :: TChan a
  , rp2pChanId :: Word32
  }

createSendP2P :: SendP2PProto a -> M (SendP2P a)
createSendP2P = undefined

createRecvP2P :: RecvP2PProto a -> M (RecvP2P a)
createRecvP2P = undefined
