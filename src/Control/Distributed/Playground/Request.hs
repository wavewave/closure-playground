{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE InstanceSigs              #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeApplications          #-}

{-# OPTIONS_GHC -fno-warn-incomplete-patterns #-}
module Control.Distributed.Playground.Request where

import Control.Distributed.Closure ( Closure
                                   , Serializable
                                   , unclosure
                                   )
import Data.Binary (Binary(get,put))
import Data.Binary.Get (Get)
import Data.Binary.Put (Put)
import qualified Data.Text as T
import Data.Traversable (for)
import Data.Typeable (Typeable)
import Data.Word (Word32)
import GHC.Generics (Generic)
import GHC.StaticPtr (StaticPtr,deRefStaticPtr,staticKey,unsafeLookupStaticPtr)
import System.IO.Unsafe (unsafePerformIO)
--
import Control.Distributed.Playground.Comm ( M
                                           , NodeName
                                           , SPort(..)
                                           , RPort(..)
                                           , receiveChan
                                           , sendChan
                                           , newChan
                                           , logText
                                           )


-- | Request handler channel has fixed id = 0
reqChanId :: Word32
reqChanId = 0

-- | Peer handler channel has fixed id = 1
peerChanId :: Word32
peerChanId = 1

-- | Peer info channel fixed id = 2
peerReqChanId :: Word32
peerReqChanId = 2

-- | Request type
data Request a b = PureRequest (Closure (a -> b)) (SPort (SPort (Maybe a))) (SPort b)
                 | MRequest (Closure (a -> M b)) (SPort (SPort (Maybe a))) (SPort b)
                 deriving (Generic, Typeable)

instance (Serializable a, Serializable b) => Binary (Request a b)


-- ref: https://github.com/haskell-distributed/cloud-haskell/issues/7
--      http://neilmitchell.blogspot.com/2017/09/existential-serialisation.html
-- | existential request type
data SomeRequest =
     forall a b. (Serializable a, Serializable b, StaticSomeRequest (Request a b), Show a, Show b)
  => SomeRequest (Request a b)

class StaticSomeRequest a where
  staticSomeRequest :: a -> StaticPtr (Get SomeRequest)

instance Binary SomeRequest where
  put :: SomeRequest -> Put
  put (SomeRequest req) = do
    put $ staticKey (staticSomeRequest req)
    put req

  get :: Get SomeRequest
  get = do
    k <- get
    case unsafePerformIO (unsafeLookupStaticPtr k) of
      Just ptr -> deRefStaticPtr ptr :: Get SomeRequest
      Nothing -> error "Binary SomeRequest: unknown static pointer"

-- | Handle an instruction by the client.
--
handleRequest ::
     (Serializable b)
  => Request a b
  -> a
  -> M b
handleRequest (PureRequest cl _ _) input =
  let fun = unclosure cl
  in pure $ fun input
handleRequest (MRequest cl _ _) input =
  let action = unclosure cl
  in action input

processRequest ::
     (Serializable a, Serializable b, Show a, Show b)
  => SPort SomeRequest
  -> SomeRequest
  -> RPort (SPort (Maybe a))
  -> RPort b
  -> [a]
  -> M [b]
processRequest sp_req sreq rp_sp rp_ans inputs = do
  sendChan sp_req sreq
  logText $ "receiving sp_input"
  sp_input <- receiveChan rp_sp
  rs <-
    for inputs $ \input -> do
      sendChan sp_input (Just input)
      ans <- receiveChan rp_ans
      logText $ "get answer = " <> T.pack (show ans)
      pure ans
  sendChan sp_input Nothing
  pure rs

callRequest ::
     forall a b. (Serializable a, Serializable b, StaticSomeRequest (Request a b), Show a, Show b)
  => SPort SomeRequest -> Closure (a -> b) -> [a] -> M [b]
callRequest sp_req clsr inputs = do
  (sp_ans,rp_ans) <- newChan @b
  (sp_sp,rp_sp) <- newChan @(SPort (Maybe a))
  let req = PureRequest clsr sp_sp sp_ans
  processRequest sp_req (SomeRequest req) rp_sp rp_ans inputs

callRequestM ::
     forall a b. (Serializable a, Serializable b, StaticSomeRequest (Request a b), Show a, Show b)
  => SPort SomeRequest -> Closure (a -> M b) -> [a] -> M [b]
callRequestM sp_req clsr inputs = do
  (sp_ans,rp_ans) <- newChan @b
  (sp_sp,rp_sp) <- newChan @(SPort (Maybe a))
  let req = MRequest clsr sp_sp sp_ans
  processRequest sp_req (SomeRequest req) rp_sp rp_ans inputs


requestTo ::
     forall a b. (Serializable a, Serializable b, StaticSomeRequest (Request a b), Show a, Show b)
  => NodeName -> Closure (a -> b) -> [a] -> M [b]
requestTo node clsr inputs =
  let sp_req = SPort node reqChanId
  in callRequest sp_req clsr inputs

requestToM ::
     forall a b. (Serializable a, Serializable b, StaticSomeRequest (Request a b), Show a, Show b)
  => NodeName -> Closure (a -> M b) -> [a] -> M [b]
requestToM node clsr inputs =
  let sp_req = SPort node reqChanId
  in callRequestM sp_req clsr inputs
