{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wall -Werror #-}
module Comm where

import Control.Concurrent (threadDelay)
import Control.Monad (void)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader (ReaderT(runReaderT))
import Data.Binary (Binary, decode, encode)
import Data.Binary.Get (getWord32le,runGet)
import Data.Binary.Put (putWord32le,runPut)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.IntMap (IntMap)
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

newtype SPort a = SPort Socket

newtype RPort a = RPort Socket

toMsg :: (Binary a) => a -> Msg
toMsg x = let bs = BL.toStrict (encode x)
              sz = fromIntegral (B.length bs)
          in Msg sz bs

fromMsg :: (Binary a) => Msg -> a
fromMsg (Msg _ bs) = decode (BL.fromStrict bs)

recvMsg :: Socket -> IO (Maybe Msg)
recvMsg sock = do
  mbs <- recv sock 4
  case mbs of
    Nothing -> pure Nothing
    Just bs -> do
      let sz = runGet getWord32le (BL.fromStrict bs)
      mbs' <- recv sock (fromIntegral sz)
      case mbs' of
        Nothing  -> pure Nothing
        Just bs' -> pure $! Just (Msg sz bs')

sendMsg :: Socket -> Msg -> IO ()
sendMsg sock (Msg sz pl) = do
  let lbs = runPut (putWord32le sz)
  send sock (BL.toStrict lbs)
  send sock pl


-------------
-- Managed --
-------------

type Managed = ReaderT (IntMap String) IO

runManaged :: Socket -> Managed () -> IO ()
runManaged _sock action =
  void $ flip runReaderT mempty $ do
    action

-------------
-- Channel --
-------------

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
