{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wall -Werror -fno-warn-unused-do-bind #-}
module Comm where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TQueue (TQueue,newTQueueIO,readTQueue,writeTQueue)
import Control.Monad (forever, void)
import Control.Monad.Loops (whileJust_)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Maybe (MaybeT(..))
import Control.Monad.Trans.Reader (ReaderT(runReaderT),ask)
import Data.Binary (Binary, decode, encode)
import Data.Binary.Get (getWord32le,runGet)
import Data.Binary.Put (putWord32le,runPut)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
-- import Data.IntMap (IntMap)
import Data.Word (Word32)
import Network.Simple.TCP (Socket, recv, send)

-------------
-- Message --
-------------

-- | simple variable length message protocol
data Msg = Msg { msgSize    :: !Word32
               , msgPayload :: !B.ByteString
               }
         deriving Show


toMsg :: (Binary a) => a -> Msg
toMsg x = let bs = BL.toStrict (encode x)
              sz = fromIntegral (B.length bs)
          in Msg sz bs

fromMsg :: (Binary a) => Msg -> a
fromMsg (Msg _ bs) = decode (BL.fromStrict bs)

recvMsg :: Socket -> IO (Maybe Msg)
recvMsg sock =
  runMaybeT $ do
    bs <- MaybeT $ recv sock 4
    let sz = runGet getWord32le (BL.fromStrict bs)
    bs' <- MaybeT $ recv sock (fromIntegral sz)
    pure $! Msg sz bs'

sendMsg :: Socket -> Msg -> IO ()
sendMsg sock (Msg sz pl) = do
  let lbs = runPut (putWord32le sz)
  send sock (BL.toStrict lbs)
  send sock pl

-------------
-- Managed --
-------------

type Managed = ReaderT {- (IntMap String) -} (TQueue Msg) IO

runManaged :: Socket -> Managed () -> IO ()
runManaged sock action = do
  queue <- newTQueueIO
  void $ flip runReaderT queue $ do
    q <- ask
    lift $ do
      forkIO $ do
        forever $ do
          msg <- atomically $ readTQueue q
          print msg
          -- threadDelay 1000000
          -- sendMsg sock (Msg 4 "test")
      forkIO $
        whileJust_ (recvMsg sock) $ \msg ->
          atomically $ writeTQueue q msg
    action

-------------
-- Channel --
-------------

newtype SPort a = SPort Socket

newtype RPort a = RPort Socket


sendChan :: (Binary a) => SPort a -> a -> Managed ()
sendChan (SPort sock) = lift . sendMsg sock . toMsg


receiveChan :: (Binary a) => RPort a -> Managed a
receiveChan rp@(RPort sock) =
  lift (recvMsg sock) >>= \case
    Nothing ->
      -- for now, we do this forever. later, we should wrap bare IO by
      -- managed network process, so Nothing case redirects to disconnect
      -- callback.
      -- TODO: fix this
      lift (threadDelay 1000000) >> receiveChan rp

    Just msg ->
      pure (fromMsg msg)
