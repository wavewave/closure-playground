{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE InstanceSigs              #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE StaticPointers            #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeApplications          #-}

{-# OPTIONS_GHC -Wall -Werror -fno-warn-incomplete-patterns #-}
module Request where

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
import GHC.Generics (Generic)
import GHC.StaticPtr (StaticPtr,deRefStaticPtr,staticKey,unsafeLookupStaticPtr)
import System.IO.Unsafe (unsafePerformIO)
--
import Comm ( Managed
            , NodeName
            , SPort(..)
            , receiveChan
            , sendChan
            , newChan
            , logText
            )

-- | Request type
data Request a b = PureRequest (Closure (a -> b)) (SPort (SPort (Maybe a))) (SPort b)
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
  -> IO b
handleRequest (PureRequest cl _ _) input =
  let fun = unclosure cl
  in pure $ fun input


callRequest ::
     forall a b. (Serializable a, Serializable b, StaticSomeRequest (Request a b), Show a, Show b)
  => SPort SomeRequest -> Closure (a -> b) -> [a] -> Managed [b]
callRequest sp_req clsr inputs = do
  (sp_ans,rp_ans) <- newChan @b
  (sp_sp,rp_sp) <- newChan @(SPort (Maybe a))
  let req = PureRequest clsr sp_sp sp_ans

  sendChan sp_req (SomeRequest req)

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

requestTo ::
     forall a b. (Serializable a, Serializable b, StaticSomeRequest (Request a b), Show a, Show b)
  => NodeName -> Closure (a -> b) -> [a] -> Managed [b]
requestTo node clsr inputs =
  let sp_req = SPort node 0 -- 0 is a special channel id.
  in callRequest sp_req clsr inputs
