#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 6;

use lib 't/lib';
use TestParser qw(:all);

parse_and_diff_yaml( <<'EOP', <<'EOE' );
x( 1, 2, , );
EOP
--- !parsetree:FunctionCall
arguments:
  - !parsetree:Constant
    flags: CONST_NUMBER|NUM_INTEGER
    value: 1
  - !parsetree:Constant
    flags: CONST_NUMBER|NUM_INTEGER
    value: 2
context: CXT_VOID
function: !parsetree:Symbol
  context: CXT_SCALAR
  name: x
  sigil: VALUE_SUB
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
x( 1, 2 or die );
EOP
--- !parsetree:FunctionCall
arguments:
  - !parsetree:BinOp
    context: CXT_LIST
    left: !parsetree:List
      expressions:
        - !parsetree:Constant
          flags: CONST_NUMBER|NUM_INTEGER
          value: 1
        - !parsetree:Constant
          flags: CONST_NUMBER|NUM_INTEGER
          value: 2
    op: OP_LOG_OR
    right: !parsetree:Overridable
      arguments: ~
      context: CXT_SCALAR
      function: die
context: CXT_VOID
function: !parsetree:Symbol
  context: CXT_SCALAR
  name: x
  sigil: VALUE_SUB
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
sub x;

x 1, 2;
EOP
--- !parsetree:SubroutineDeclaration
name: x
--- !parsetree:FunctionCall
arguments:
  - !parsetree:Constant
    flags: CONST_NUMBER|NUM_INTEGER
    value: 1
  - !parsetree:Constant
    flags: CONST_NUMBER|NUM_INTEGER
    value: 2
context: CXT_VOID
function: !parsetree:Symbol
  context: CXT_SCALAR
  name: x
  sigil: VALUE_SUB
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
sub x { };

x 1, 2;
EOP
--- !parsetree:NamedSubroutine
lines: []
name: x
--- !parsetree:FunctionCall
arguments:
  - !parsetree:Constant
    flags: CONST_NUMBER|NUM_INTEGER
    value: 1
  - !parsetree:Constant
    flags: CONST_NUMBER|NUM_INTEGER
    value: 2
context: CXT_VOID
function: !parsetree:Symbol
  context: CXT_SCALAR
  name: x
  sigil: VALUE_SUB
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
print, 1,
print, 1;
EOP
--- !parsetree:List
expressions:
  - !parsetree:BuiltinIndirect
    arguments: ~
    context: CXT_VOID
    function: print
    indirect: ~
  - !parsetree:Constant
    flags: CONST_NUMBER|NUM_INTEGER
    value: 1
  - !parsetree:BuiltinIndirect
    arguments: ~
    context: CXT_VOID
    function: print
    indirect: ~
  - !parsetree:Constant
    flags: CONST_NUMBER|NUM_INTEGER
    value: 1
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
print, 1,
print => 1;
EOP
--- !parsetree:List
expressions:
  - !parsetree:BuiltinIndirect
    arguments: ~
    context: CXT_VOID
    function: print
    indirect: ~
  - !parsetree:Constant
    flags: CONST_NUMBER|NUM_INTEGER
    value: 1
  - !parsetree:Constant
    flags: CONST_STRING
    value: print
  - !parsetree:Constant
    flags: CONST_NUMBER|NUM_INTEGER
    value: 1
EOE
