{-# LANGUAGE MultiParamTypeClasses, TypeFamilies, OverloadedStrings, DataKinds, TypeOperators, TypeSynonymInstances, FlexibleInstances #-}
module WebApi.RouteSpec where

import WebApi
import WebApi.Internal
import Data.Text (Text)
import Test.Hspec
import Test.Hspec.Wai
import qualified Network.Wai as Wai

withApp :: SpecWith Wai.Application -> Spec
withApp = with (return routingSpecApp)

routingSpecApp :: Wai.Application
routingSpecApp = serverApp serverSettings RoutingSpecImpl

data RoutingSpec     = RoutingSpec
data RoutingSpecImpl = RoutingSpecImpl

type StaticRoute1 = "this" :/ "is" :/ "a" :/ "static" :/ "route"
type StaticRoute2 = Static "static_route"

type RouteWithParam        = "param" :/ Int
type RouteWithParamAtBegin = Bool :/ "param"
type RouteWithParams       = Text :/ "param1" :/ Int :/ "param2"
type OverlappingRoute      = "foo" :/ "param1" :/ Int :/ "param2"

instance WebApi RoutingSpec where
  type Version RoutingSpec = MajorMinor '(0, 1)
  type Apis    RoutingSpec = '[ Route GET StaticRoute1
                              , Route GET StaticRoute2  
                              , Route GET RouteWithParam
                              , Route GET RouteWithParamAtBegin
                              , Route GET OverlappingRoute
                              , Route GET RouteWithParams
                              ]

instance API RoutingSpec GET StaticRoute1 where
  type ApiOut GET StaticRoute1 = ()

instance API RoutingSpec GET StaticRoute2 where
  type ApiOut GET StaticRoute2 = ()

instance API RoutingSpec GET RouteWithParam where
  type ApiOut GET RouteWithParam = ()

instance API RoutingSpec GET RouteWithParamAtBegin where
  type ApiOut GET RouteWithParamAtBegin = Text

instance API RoutingSpec GET RouteWithParams where
  type ApiOut GET RouteWithParams = Text

instance API RoutingSpec GET OverlappingRoute where
  type ApiOut GET OverlappingRoute = Text

instance ApiProvider RoutingSpec where
  type HandlerM RoutingSpec = IO

type instance ApiInterface RoutingSpecImpl = RoutingSpec

instance Server RoutingSpecImpl GET StaticRoute1 where
  handler _ _ _ = respond ()

instance Server RoutingSpecImpl GET StaticRoute2 where
  handler _ _ _ = respond ()

instance Server RoutingSpecImpl GET RouteWithParam where
  handler _ _ _ = respond ()

instance Server RoutingSpecImpl GET RouteWithParamAtBegin where
  handler _ _ _ = respond "RouteWithParamAtBegin"

instance Server RoutingSpecImpl GET RouteWithParams where
  handler _ _ _ = respond "RouteWithParams"

instance Server RoutingSpecImpl GET OverlappingRoute where
  handler _ _ _ = respond "OverlappingRoute"


routeSpec :: Spec
routeSpec = withApp $ describe "WebApi routing" $ do
  context "static route with only one piece" $ do
    it "should be 200 ok" $ do
      get "static_route" `shouldRespondWith` 200
  context "static route with many pieces" $ do
    it "should be 200 ok" $ do
      get "this/is/a/static/route" `shouldRespondWith` 200
  context "route with param" $ do
    it "should be 200 ok" $ do
      get "param/5" `shouldRespondWith` 200
  context "route with param at beginning" $ do
    it "should be 200 ok returning RouteWithParamAtBegin" $ do
      get "True/param" `shouldRespondWith` "RouteWithParamAtBegin" { matchStatus = 200 }
  context "route with multiple params" $ do
    it "should be 200 ok returning RouteWithParams" $ do
      get "bar/param1/5/param2" `shouldRespondWith` "RouteWithParams" { matchStatus = 200 }
  context "overlapping route selected by order" $ do
    it "should be 200 ok returning OverlappingRoute" $ do
      get "foo/param1/5/param2" `shouldRespondWith` "OverlappingRoute" { matchStatus = 200 }
  context "non existing route" $ do
    it "should be 404 ok" $ do
      get "foo/param1/5/param3" `shouldRespondWith` 404
  