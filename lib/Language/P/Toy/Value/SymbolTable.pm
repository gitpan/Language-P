package Language::P::Toy::Value::SymbolTable;

use strict;
use warnings;
use base qw(Language::P::Toy::Value::Any);

__PACKAGE__->mk_ro_accessors( qw(symbols) );

use Language::P::Toy::Value::Typeglob;

sub type { 7 }
sub is_main { 0 }

sub new {
    my( $class, $args ) = @_;
    my $self = $class->SUPER::new( $args );

    $self->{symbols} ||= {};

    return $self;
}

sub get_package {
    my( $self, $package ) = @_;

    return $self if $self->is_main && $package eq 'main';

    die 'Implement me';
}

our %sigils =
  ( '$'  => [ 'scalar',     'Language::P::Toy::Value::Scalar' ],
    '@'  => [ 'array',      'Language::P::Toy::Value::Array' ],
    '%'  => [ 'hash',       'Language::P::Toy::Value::Hash' ],
    '&'  => [ 'subroutine', 'Language::P::Toy::Value::Subroutine' ],
    '*'  => [ undef,        'Language::P::Toy::Value::Typeglob' ],
    'I'  => [ 'io',         'Language::P::Toy::Value::Handle' ],
    'F'  => [ 'format',     'Language::P::Toy::Value::Format' ],
    '::' => [ undef,        'language::P::Value::SymbolTable' ],
    );

sub get_symbol {
    my( $self, $name, $sigil, $create ) = @_;
    my( $symbol, $created ) = $self->_get_symbol( $name, $sigil, $create );

    return $symbol;
}

sub _get_symbol {
    my( $self, $name, $sigil, $create ) = @_;
    my( @packages ) = split /::/, $name;
    if( $self->is_main && ( $packages[0] eq '' || $packages[0] eq 'main' ) ) {
        shift @packages;
    }

    my $index = 0;
    my $current = $self;
    foreach my $package ( @packages ) {
        if( $index == $#packages ) {
            return $current if $sigil eq '::';
            my $glob = $current->{symbols}{$package};
            my $created = 0;
            return ( undef, $created ) if !$glob && !$create;
            if( !$glob ) {
                $created = 1;
                $glob = $current->{symbols}{$package} =
                    Language::P::Toy::Value::Typeglob->new;
            }
            return ( $glob, $created ) if $sigil eq '*';
            return ( $glob->get_slot( $sigils{$sigil}[0] ), $created );
        } else {
            my $subpackage = $package . '::';
            if( !exists $current->{symbols}{$subpackage} ) {
                return ( undef, 0 ) unless $create;

                $current = $current->{symbols}{$subpackage} =
                  Language::P::Toy::Value::SymbolTable->new;
            } else {
                $current = $current->{symbols}{$subpackage};
            }
        }

        ++$index;
    }
}

sub set_symbol {
    my( $self, $name, $sigil, $value ) = @_;
    my $glob = $self->get_symbol( $name, '*', 1 );

    $glob->set_slot( $sigils{$sigil}[0], $value );

    return;
}

1;
