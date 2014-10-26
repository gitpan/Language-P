#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 5;

use lib 't/lib';
use TestParser qw(:all);

parse_and_diff_yaml( <<'EOP', <<'EOE' );
print <<EOT
test
EOT
EOP
--- !parsetree:BuiltinIndirect
arguments:
  - !parsetree:Constant
    context: CXT_LIST
    flags: CONST_STRING
    value: "test\n"
context: CXT_VOID
function: OP_PRINT
indirect: ~
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
print <<EOT
$a
EOT
EOP
--- !parsetree:BuiltinIndirect
arguments:
  - !parsetree:QuotedString
    components:
      - !parsetree:Symbol
        context: CXT_SCALAR
        name: a
        sigil: VALUE_SCALAR
      - !parsetree:Constant
        context: CXT_SCALAR
        flags: CONST_STRING
        value: "\n"
context: CXT_VOID
function: OP_PRINT
indirect: ~
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
print << "EOT"
$a
EOT
EOP
--- !parsetree:BuiltinIndirect
arguments:
  - !parsetree:QuotedString
    components:
      - !parsetree:Symbol
        context: CXT_SCALAR
        name: a
        sigil: VALUE_SCALAR
      - !parsetree:Constant
        context: CXT_SCALAR
        flags: CONST_STRING
        value: "\n"
context: CXT_VOID
function: OP_PRINT
indirect: ~
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
print << 'EOT'
$a
EOT
EOP
--- !parsetree:BuiltinIndirect
arguments:
  - !parsetree:Constant
    context: CXT_LIST
    flags: CONST_STRING
    value: "$a\n"
context: CXT_VOID
function: OP_PRINT
indirect: ~
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
print << `EOT`
ls
EOT
EOP
--- !parsetree:BuiltinIndirect
arguments:
  - !parsetree:UnOp
    context: CXT_LIST
    left: !parsetree:Constant
      context: CXT_SCALAR
      flags: CONST_STRING
      value: "ls\n"
    op: OP_BACKTICK
context: CXT_VOID
function: OP_PRINT
indirect: ~
EOE
