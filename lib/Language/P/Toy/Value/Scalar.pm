package Language::P::Toy::Value::Scalar;

use strict;
use warnings;
use base qw(Language::P::Toy::Value::Any);

sub type { 5 }

sub as_scalar { return $_[0] }

sub assign {
    my( $self, $other ) = @_;

    Carp::confess if ref( $other ) eq __PACKAGE__;

    # FIXME proper morphing
    %$self = ();
    bless $self, ref( $other );

    $self->assign( $other );
}

sub assign_iterator {
    my( $self, $iter ) = @_;

    die unless $iter->next; # FIXME, must assign undef
    $self->assign( $iter->item );
}

1;
