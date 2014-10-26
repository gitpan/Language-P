#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 2;

use lib qw(t/lib);
use TestIntermediate qw(:all);

generate_tree_and_diff( <<'EOP', <<'EOI' );
$x = $a > 2 ? $b : $c + 3;
EOP
# main
L1:
  jump_if_f_gt (global name=a, slot=1), (constant_integer 2), L3
  jump L4
L2:
  assign (global name=x, slot=1), (get t3)
  end
L3:
  set t1, (global name=b, slot=1)
  set t3, (get t1)
  jump L2
L4:
  set t2, (add (global name=c, slot=1), (constant_integer 3))
  set t3, (get t2)
  jump L2
EOI

generate_tree_and_diff( <<'EOP', <<'EOI' );
$x = $a > 2 ? $b :
     $c < 3 ? $d : $e;
EOP
# main
L1:
  jump_if_f_gt (global name=a, slot=1), (constant_integer 2), L3
  jump L4
L2:
  assign (global name=x, slot=1), (get t4)
  end
L3:
  set t1, (global name=b, slot=1)
  set t4, (get t1)
  jump L2
L4:
  jump_if_f_lt (global name=c, slot=1), (constant_integer 3), L6
  jump L7
L6:
  set t2, (global name=d, slot=1)
  set t4, (get t2)
  jump L2
L7:
  set t3, (global name=e, slot=1)
  set t4, (get t3)
  jump L2
EOI
