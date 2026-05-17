-- Higher-order folds + ADTs. Compile: ghc Main.hs && ./Main

module Main where

import Data.List (sortBy)
import Data.Ord (comparing, Down(..))

data Shape
  = Circle Double
  | Rectangle Double Double
  | Triangle Double Double
  deriving (Show)

area :: Shape -> Double
area (Circle r)        = pi * r * r
area (Rectangle w h)   = w * h
area (Triangle b h)    = 0.5 * b * h

-- Tail-recursive sum
sumAreas :: [Shape] -> Double
sumAreas = foldr ((+) . area) 0

-- Sort by area descending
biggestFirst :: [Shape] -> [Shape]
biggestFirst = sortBy (comparing (Down . area))

describe :: Shape -> String
describe s = name s ++ " with area " ++ show (area s)
  where
    name (Circle _)      = "circle"
    name (Rectangle _ _) = "rectangle"
    name (Triangle _ _)  = "triangle"

main :: IO ()
main = do
  let shapes = [Circle 3, Rectangle 4 5, Triangle 6 4, Circle 1.5]
  putStrLn $ "total area: " ++ show (sumAreas shapes)
  mapM_ (putStrLn . ("  " ++) . describe) (biggestFirst shapes)
