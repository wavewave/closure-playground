{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wall -Werror #-}
module Control.Distributed.Playground.Comm where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM ( TChan
                              , TVar
                              , atomically
                              , newTVarIO
                              , readTVar
                              , readTVarIO
                              , writeTVar
                              , newTChan
                              , readTChan
                              , writeTChan
                              )
import Control.Concurrent.STM.TQueue (TQueue,newTQueueIO,readTQueue,writeTQueue)
import Control.Monad (forever, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Loops (whileJust_)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Maybe (MaybeT(..))
import Control.Monad.Trans.Reader (ReaderT(runReaderT),ask)
import Data.Binary (Binary(get,put), decode, encode)
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

data BinProxy a = BinProxy

instance Binary (BinProxy a) where
  put BinProxy = mempty
  get          = pure BinProxy

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
    !bs' <- MaybeT $ recv sock (fromIntegral sz)
    pure $! Msg sz bs'

sendMsg :: Socket -> Msg -> IO ()
sendMsg sock (Msg sz pl) = do
  let !lbs = runPut (putWord32le sz)
  send sock (BL.toStrict lbs)
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
    !payload <- MaybeT $ recv sock (fromIntegral sz)
    pure $! IMsg i (Msg sz payload)


sendIMsg :: Socket -> IMsg -> IO ()
sendIMsg sock (IMsg i (Msg sz pl)) = do
  let !lb_i  = runPut (putWord32le i)
  send sock (BL.toStrict lb_i)
  let !lb_sz = runPut (putWord32le sz)
  send sock (BL.toStrict lb_sz)
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
  , chLogQueue :: !(TQueue Text)
  }

initChanState :: NodeName -> SocketPool -> IO ChanState
initChanState name pool =
      ChanState name
  <$> newTVarIO pool
  <*> newTQueueIO
  <*> newTVarIO mempty
  <*> newTQueueIO

type M = ReaderT ChanState IO

router :: M ()
router = void $ do
  ChanState _ pool queue mref _ <- ask
  -- routing message to channel
  void $ lift $ forkIO $
    forever $ do
      IMsg i msg <- atomically $ readTQueue queue
      m <- readTVarIO mref
      for_ (M.lookup i m) $ \ch -> do
        atomically $ writeTChan ch msg
  -- receiving gateway
  SocketPool sockmap <- liftIO $ readTVarIO pool
  for_ sockmap $ \(sock,_) ->
    lift $ forkIO $
      whileJust_ (recvIMsg sock) $ \imsg ->
        atomically $ writeTQueue queue imsg

logger :: M ()
logger = void $ do
  lq <- chLogQueue <$> ask
  lift $ forkIO $ do
    forever $ do
      txt <- atomically $ readTQueue lq
      TIO.putStrLn txt

runManaged :: NodeName -> SocketPool -> M a -> IO a
runManaged name pool action = do
  chst <- initChanState name pool
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
  ChanState self _ _ mref _ <- ask
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
  ChanState self _ _ mref _ <- ask
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
