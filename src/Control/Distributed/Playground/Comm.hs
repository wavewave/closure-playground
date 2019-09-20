{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Control.Distributed.Playground.Comm where

import Control.Concurrent.STM ( TChan
                              , TVar
                              , atomically
                              , retry
                              , newTVarIO
                              , readTVar
                              , readTVarIO
                              , writeTVar
                              , newTChan
                              , readTChan
                              , writeTChan
                              )
import Control.Concurrent.STM.TQueue (TQueue,newTQueueIO,readTQueue,writeTQueue)
import Control.Monad ( forever, void, when )
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Loops (whileJust_)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Maybe (MaybeT(..))
import Control.Monad.Trans.Reader (ReaderT(runReaderT),ask)
import Control.Monad.Trans.State (runStateT)
import qualified Control.Monad.Trans.State as S
import Data.Binary (Binary, decode, encode)
import Data.Binary.Get (getWord32le,runGet)
import Data.Binary.Put (putWord32le,runPut)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (for_)
import Data.Hashable (Hashable)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Data.Typeable (Typeable)
import qualified Data.Text.IO as TIO
import Data.Word (Word32)
import GHC.Generics (Generic)
import Network.Simple.TCP (Socket, SockAddr, recv, send)
import UnliftIO.Concurrent (forkIO)

-------------
-- Message --
-------------

-- | simple variable length message protocol
data Msg = Msg { msgSize    :: !Word32
               , msgPayload :: !B.ByteString
               }
         deriving Show


toMsg :: (Binary a) => a -> Msg
toMsg x = let !bs = BL.toStrict (encode x)
              !sz = fromIntegral (B.length bs)
          in Msg sz bs

fromMsg :: (Binary a) => Msg -> a
fromMsg (Msg _ bs) = decode (BL.fromStrict bs)

recvMsg :: Socket -> IO (Maybe Msg)
recvMsg sock =
  runMaybeT $ do
    !bs <- MaybeT $ recv sock 4
    let sz = runGet getWord32le (BL.fromStrict bs)
    if sz > 0
      then do
        !bs' <- MaybeT $ recv sock (fromIntegral sz)
        pure $! Msg sz bs'
      else
        -- Zero length message should be treated specially.
        -- Otherwise, the following error happens.
        -- "Network.Socket.recvBuf: invalid argument (non-positive length)"
        pure $! Msg sz ""

sendMsg :: Socket -> Msg -> IO ()
sendMsg sock (Msg sz pl) = do
  let !lbs = runPut (putWord32le sz)
  send sock (BL.toStrict lbs)
  when (sz > 0) $
    send sock pl

-- | message with target id
data IMsg = IMsg { imsgReceiver :: !Word32
                 , imsgMsg      :: !Msg
                }
         deriving Show

recvIMsg :: Socket -> IO (Maybe IMsg)
recvIMsg sock = do
  runMaybeT $ do
    !bs1 <- MaybeT $ recv sock 4
    let i = runGet getWord32le (BL.fromStrict bs1)
    !bs2 <- MaybeT $ recv sock 4
    let sz = runGet getWord32le (BL.fromStrict bs2)
    if sz > 0
      then do
        !payload <- MaybeT $ recv sock (fromIntegral sz)
        pure $! IMsg i (Msg sz payload)
      else
        -- Zero length message should be treated specially.
        -- Otherwise, the following error happens.
        -- "Network.Socket.recvBuf: invalid argument (non-positive length)"
        pure $! IMsg i (Msg sz "")


sendIMsg :: Socket -> IMsg -> IO ()
sendIMsg sock (IMsg i (Msg sz pl)) = do
  let !lb_i  = runPut (putWord32le i)
  send sock (BL.toStrict lb_i)
  let !lb_sz = runPut (putWord32le sz)
  send sock (BL.toStrict lb_sz)
  when (sz > 0) $
    send sock pl

-------------
-- Managed --
-------------

newtype NodeName = NodeName { unNodeName :: Text }
                 deriving (Show, Eq, Ord, Hashable, Binary, Typeable)

newtype SocketPool = SocketPool {
    sockPoolMap :: HashMap NodeName (Socket,SockAddr)
  }


data ChanState = ChanState {
    chName :: !NodeName
  , chSockets :: !(TVar SocketPool)
  , chQueue :: !(TQueue IMsg)
  , chChanMap :: !(TVar (Map Word32 (TChan Msg)))
  , chP2PNext :: !(TVar Word32)  -- TODO: change this to map
  , chLogQueue :: !(TQueue Text)
  }

initChanState :: NodeName -> TVar SocketPool -> IO ChanState
initChanState name ref_pool =
      ChanState name ref_pool
  <$> newTQueueIO
  <*> newTVarIO mempty
  <*> newTVarIO 0
  <*> newTQueueIO

type M = ReaderT ChanState IO

gateway :: M ()
gateway = do
  ChanState _ pool queue _ _ _ <- ask
  -- check
  void $ forkIO $ void $ flip runStateT HM.empty $ do
    forever $ do
      conns <- S.get
      (conns',diff) <-
        liftIO $ atomically $ do
          SocketPool conns' <- readTVar pool
          let diff = conns' `HM.difference` conns
          if HM.null diff
            then retry
            else pure (conns',diff)
      S.put conns'
      for_ diff $ \(sock,_) ->
        liftIO $ forkIO $
          whileJust_ (recvIMsg sock) $ \imsg ->
            atomically $ writeTQueue queue imsg

router :: M ()
router = void $ do
  ChanState _ _ queue mref _ _ <- ask
  -- routing message to channel
  void $ lift $ forkIO $
    forever $ do
      IMsg i msg <- atomically $ readTQueue queue
      m <- readTVarIO mref
      for_ (M.lookup i m) $ \ch -> do
        atomically $ writeTChan ch msg
  -- receiving gateway
  gateway

logger :: M ()
logger = void $ do
  lq <- chLogQueue <$> ask
  lift $ forkIO $ do
    forever $ do
      txt <- atomically $ readTQueue lq
      TIO.putStrLn txt

runManaged :: NodeName -> TVar SocketPool -> M a -> IO a
runManaged name ref_pool action = do
  chst <- initChanState name ref_pool
  flip runReaderT chst $ do
    router
    logger
    action

getSelfName :: M NodeName
getSelfName = chName <$> ask

getPool :: M SocketPool
getPool = liftIO . readTVarIO =<< chSockets <$> ask

-------------
-- Logging --
-------------

logText :: Text -> M ()
logText txt = do
  lq <- chLogQueue <$> ask
  lift $ atomically $ writeTQueue lq txt

-------------
-- Channel --
-------------

data SPort a = SPort {
    spNodeId :: NodeName
  , spChanId :: Word32
  }
  deriving (Generic,Typeable)

instance Binary (SPort a)

data RPort a = RPort {
    rpChanId :: Word32
  , rpChannel :: TChan Msg
  }

newChan :: M (SPort a, RPort a)
newChan = do
  ChanState self _ _ mref _ _ <- ask
  lift $
    atomically $ do
      m <- readTVar mref
      let ks = M.keys m
          newid = if null ks then 0 else maximum ks + 1
      ch <- newTChan
      let !m' = M.insert newid ch m
      writeTVar mref m'
      pure (SPort self newid, RPort newid ch)

newChanWithId :: Word32 -> M (Maybe  (SPort a, RPort a))
newChanWithId newid = do
  ChanState self _ _ mref _ _ <- ask
  lift $
    atomically $ do
      m <- readTVar mref
      let ks = M.keys m
      if newid `elem` ks
        then pure Nothing
        else do
          ch <- newTChan
          let !m' = M.insert newid ch m
          writeTVar mref m'
          pure $ Just (SPort self newid, RPort newid ch)

sendChan :: (Binary a) => SPort a -> a -> M ()
sendChan (SPort n i) x = do
  SocketPool sockMap <- getPool
  case HM.lookup n sockMap of
    Nothing -> logText "connection doesn't exist"
    Just (sock,_) ->
      lift $ sendIMsg sock (IMsg i (toMsg x))

receiveChan :: (Binary a) => RPort a -> M a
receiveChan (RPort _ chan) =
  fromMsg <$> lift (atomically (readTChan chan))
