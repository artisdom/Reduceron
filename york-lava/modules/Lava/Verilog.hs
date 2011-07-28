module Lava.Verilog(writeVerilog) where

{-
BUG:
#1: using both writeVerilog and writeVhdl, or either twice, doesn't work.
    Side-effects corrupting the netlist?

Suggestions for improvements:
- inline everything that isn't shared (drops the # of defined wires dramatically)
- use true Verilog addition rather than try to created it by hand (TBD)
- instead of using individual wires for busses, use the [N-1:0] Verilog notation.
  (mostly affects memories).
-}

import Lava.Bit
import Lava.Binary
import System
import Numeric (showHex)

verilogModuleHeader :: String -> Netlist -> String
verilogModuleHeader name nl =
  "module " ++ name ++ "(\n" ++
  consperse ",\n"
       ([ "  input " ++ v | v <- "clock":inps, check v] ++
        [ "  output " ++ v | v <- outs, check v]) ++
  ");\n\n"
  where
    inps = [ lookupParam (netParams net) "name"
           | net <- nets nl, netName net == "name"]
    outs = map fst (namedOutputs nl)

check name = if name `elem` reserved then
                error $ "`" ++ name ++ "' is a reserved Verilog keyword"
             else
                True
             where
             reserved = ["module", "input", "output", "inout", "reg", "wire", "for",
                         "always", "assign", "begin", "end", "endmodule"]

verilogDecls :: Netlist -> String
verilogDecls nl =
  bracket "  wire " ";\n"
        [ consperse ", " $ map (wireStr . (,) (netId net)) [0..netNumOuts net - 1]
        | net <- wires ]
  ++
  bracket "  reg " ";\n"
        [ consperse ", " $ map (regFormat net) [0..netNumOuts net - 1]
        | net <- regs ]
  where
    bracket pre post xs = concat [pre ++ x ++ post | x <- xs]
    regFormat net 0 = wireStr (netId net, 0) ++ " = " ++ init net
    regFormat net y = error "unexpected output arity of a register"

    -- I'm sure there's a "partition" function for this
    wires = [ net | net <- nets nl
            , netName net /= "delay" && netName net /= "delayEn" ]
    regs = [ net | net <- nets nl
            , netName net == "delay" || netName net == "delayEn" ]
    init :: Net -> String
    init net = lookupParam (netParams net) "init"

type Instantiator = String -> [Parameter] -> InstanceId -> [Wire] -> String

verilogInsts :: Netlist -> String
verilogInsts nl =
  concat [ verilogInst (netName net)
             (netParams net)
             (netId net)
             (netInputs net)
         | net <- nets nl ] ++
  concat [ "  assign " ++ s ++ " = " ++ wireStr w ++ ";\n"
         | (s, w) <- namedOutputs nl ]

verilogInst :: Instantiator
verilogInst "low"     = constant "0"
verilogInst "high"    = constant "1"
verilogInst "inv"     = gate 1 "~"
verilogInst "and2"    = gate 1 "&"
verilogInst "or2"     = gate 1 "|"
verilogInst "xor2"    = gate 1 "^"
verilogInst "eq2"     = gate 1 "=="
verilogInst "xorcy"   = gate 1 "^" -- makes no distinction between xorcy and xor2
verilogInst "muxcy"   = muxcyInst
verilogInst "name"    = assignName
verilogInst "delay"   = delay False
verilogInst "delayEn" = delay True
verilogInst "ram"     = instRam
verilogInst "dualRam" = instRam2
verilogInst s = error ("Verilog: unknown component '" ++ s ++ "'")

muxcyInst params dst [ci,di,s] =
  "  assign " ++ wireStr (dst, 0) ++ " = " ++
  wireStr s ++ " ? " ++ wireStr ci ++ " : " ++ wireStr di ++ ";\n"

ramFiles :: Netlist -> [(String, String)]
ramFiles nl =
    [ ( "ram_" ++ compStr (netId net) ++ ".txt"
      , genMemInitFile $ netParams net)
    | net <- nets nl
    , netName net == "ram" || netName net == "dualRam"
    , nonEmpty (netParams net)
    ]
  where
    init params = read (lookupParam params "init") :: [Integer]
    nonEmpty params = not $ null $ init params
    genMemInitFile params = unlines (map (`showHex` "") (init params))

verilog :: String -> Netlist -> [(String, String)]
verilog name nl =
  [ (name ++ ".v",

     "// Portable Verilog generated by York Lava, Californicated\n"
     ++ verilogModuleHeader name nl
     ++ verilogDecls nl
     ++ verilogInsts nl
     ++ "endmodule\n") ] ++
  ramFiles nl

{-|
For example, the function

> halfAdd :: Bit -> Bit -> (Bit, Bit)
> halfAdd a b = (sum, carry)
>   where
>     sum   = a <#> b
>     carry = a <&> b

can be converted to a Verilog entity with inputs named @a@ and @b@ and
outputs named @sum@ and @carry@.

> synthesiseHalfAdd :: IO ()
> synthesiseHalfAdd =
>   writeVerilog "HalfAdd"
>             (halfAdd (name "a") (name "b"))
>             (name "sum", name "carry")
-}
writeVerilog ::
  Generic a => String -- ^ The name of VERILOG entity, which is also the
                      -- name of the directory that the output files
                      -- are written to.
            -> a      -- ^ The Bit-structure that is turned into VERILOG.
            -> a      -- ^ Names for the outputs of the circuit.
            -> IO ()
writeVerilog name a b =
  do putStrLn ("Creating directory '" ++ name ++ "/'")
     system ("mkdir -p " ++ name)
     nl <- netlist a b
     mapM_ gen (verilog name nl)
     putStrLn "Done."
  where
    gen (file, content) =
      do putStrLn $ "Writing to '" ++ name ++ "/" ++ file ++ "'"
         writeFile (name ++ "/" ++ file) content

-- Auxiliary functions

compStr :: InstanceId -> String
compStr i = "c" ++ show i

wireStr :: Wire -> String
wireStr (i, 0) = "w" ++ show i
wireStr (i, j) = "w" ++ show i ++ "_" ++ show j

consperse :: String -> [String] -> String
consperse s [] = ""
consperse s [x] = x
consperse s (x:y:ys) = x ++ s ++ consperse s (y:ys)

argList :: [String] -> String
argList = consperse ","

gate 1 str params comp [i1,i2] =
  "  assign " ++ dest ++ " = " ++ x ++ " " ++ str ++ " " ++ y ++ ";\n"
  where dest = wireStr (comp, 0)
        [x,y] = map wireStr [i1,i2]

gate n str params comp [i] =
  "  assign " ++ dest ++ " = " ++ str ++ wireStr i ++ ";\n"
  where dest = wireStr (comp, 0)

gate n str params comp inps = error $ "gate wasn't expecting " ++ str ++ "," ++ show inps

assignName params comp inps =
  "  assign " ++ wireStr (comp, 0)  ++ " = " ++ lookupParam params "name" ++ ";\n"

constant str params comp inps =
  "  assign " ++ wireStr (comp, 0) ++ " = " ++ str ++ ";\n"

v_always_at_posedge_clock stmt = "  always @(posedge clock) " ++ stmt ++ "\n"
v_assign dest source = dest ++ " <= " ++ source ++ ";"
v_if_then cond stmt = "if (" ++ cond ++ ") " ++ stmt
v_block stmts = "begin\n" ++
                concat ["    " ++ s ++ "\n" | s <- stmts ] ++
                "  end\n" -- Indents needs more cleverness, like a Doc

delay :: Bool -> [Parameter] -> Int -> [Wire] -> String
delay False params comp [_, d] =
  v_always_at_posedge_clock (wireStr (comp, 0) `v_assign` wireStr d)

delay True params comp [_, ce, d] =
  v_always_at_posedge_clock (v_if_then (wireStr ce) (wireStr (comp, 0) `v_assign` wireStr d))

{-
  reg [dwidth-1:0] ram[(1 << awidth) - 1: 0];
  initial $readmemh(RAM_INIT_FILE, ram);  // list of hexidecimal numbers without prefix, eg. "2a\n33ff\n..."
  always @(posedge clock) begin
     {outs1!!(dwidth-1), ..., outs1!!0} <= ram[{abus1,...abus1}];
     if (we) ram[{abus1,...abus1}] <= {dbus1!!(dwidth-1), ..., dbus1!!0};
  end
-}

vBus :: [Wire] -> String
vBus bus = "{" ++ argList (map wireStr (reverse bus)) ++ "}" -- XXX is reverse correct?

declRam :: String -> Int -> Int -> String
declRam ramName dwidth awidth =
  "  reg [" ++ show (dwidth-1) ++ ":0] " ++ ramName ++ "[" ++ show (2^awidth - 1) ++ ":0];\n"

initRam :: String -> String
initRam ramName =
  "  initial $readmemh(\"" ++ ramName ++ ".txt\", " ++ ramName ++ ");\n"

instRam params comp (we:sigs) =
    declRam ramName dwidth awidth ++
    "  reg [" ++ show (awidth-1) ++ ":0] " ++ hackOut1 ++ " = 0;\n" ++
    "  assign " ++ vBus outs1 ++ " = " ++ ramName ++ "[" ++ hackOut1 ++ "];\n" ++
    (if null init then "" else initRam ramName) ++
    v_always_at_posedge_clock
      (v_block
        [ v_assign hackOut1 (vBus abus1)
        , v_if_then (wireStr we)
             (v_assign (ramName ++ "[" ++ vBus abus1 ++ "]") (vBus dbus1))
        ])
  where
    ramName = "ram_" ++ compStr comp
    hackOut1 = ramName ++ "_out1"
    init = read (lookupParam params "init") :: [Integer]
    dwidth = read (lookupParam params "dwidth") :: Int
    awidth = read (lookupParam params "awidth") :: Int

    (dbus1, abus1) = splitAt dwidth sigs
    outs1          = map ((,) comp) [0..dwidth-1]


instRam2 params comp (we1:we2:sigs) =
    declRam ramName dwidth awidth ++
    "  reg [" ++ show (awidth-1) ++ ":0] " ++ hackOut1 ++ " = 0;\n" ++
    "  reg [" ++ show (awidth-1) ++ ":0] " ++ hackOut2 ++ " = 0;\n" ++
    "  assign " ++ vBus outs1 ++ " = " ++ ramName ++ "[" ++ hackOut1 ++ "];\n" ++
    "  assign " ++ vBus outs2 ++ " = " ++ ramName ++ "[" ++ hackOut2 ++ "];\n" ++
    (if null init then "" else initRam ramName) ++
    v_always_at_posedge_clock
      (v_block
        [ v_assign hackOut1 (vBus abus1)
        , v_if_then (wireStr we1)
             (v_assign (ramName ++ "[" ++ vBus abus1 ++ "]") (vBus dbus1))
        , v_assign hackOut2 (vBus abus2)
        , v_if_then (wireStr we2)
             (v_assign (ramName ++ "[" ++ vBus abus2 ++ "]") (vBus dbus2))
        ])
  where
    ramName = "ram_" ++ compStr comp
    hackOut1 = ramName ++ "_out1"
    hackOut2 = ramName ++ "_out2"
    init = read (lookupParam params "init") :: [Integer]
    dwidth = read (lookupParam params "dwidth") :: Int
    awidth = read (lookupParam params "awidth") :: Int

    (dbus, abus)   = splitAt (2*dwidth) sigs
    (abus1, abus2) = splitAt awidth abus
    (dbus1, dbus2) = splitAt dwidth dbus
    outs1          = map ((,) comp) [0..dwidth-1]
    outs2          = map ((,) comp) [dwidth..dwidth*2-1]
