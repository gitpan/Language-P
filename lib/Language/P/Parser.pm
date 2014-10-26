package Language::P::Parser;

use strict;
use warnings;
use base qw(Class::Accessor::Fast);

use Language::P::Lexer qw(:all);
use Language::P::ParseTree qw(:all);
use Language::P::Parser::Regex;
use Language::P::Parser::Lexicals;
use Language::P::Keywords;

__PACKAGE__->mk_ro_accessors( qw(lexer generator runtime) );
__PACKAGE__->mk_accessors( qw(_package _lexicals _pending_lexicals
                              _in_declaration _lexical_state
                              _options) );

sub _lexical_sub_state { $_[0]->{_lexical_state}->[-1]->{sub} }

use constant
  { PREC_HIGHEST       => 0,
    PREC_NAMED_UNOP    => 10,
    PREC_TERNARY       => 18,
    PREC_TERNARY_COLON => 40,
    PREC_LISTEXPR      => 19,
    PREC_COMMA         => 20,
    PREC_LISTOP        => 21,
    PREC_LOWEST        => 50,

    BLOCK_OPEN_SCOPE      => 1,
    BLOCK_IMPLICIT_RETURN => 2,
    BLOCK_BARE            => 4,

    ASSOC_LEFT         => 1,
    ASSOC_RIGHT        => 2,
    ASSOC_NON          => 3,
    };

my %token_to_sigil =
  ( T_DOLLAR()    => VALUE_SCALAR,
    T_AT()        => VALUE_ARRAY,
    T_PERCENT()   => VALUE_HASH,
    T_STAR()      => VALUE_GLOB,
    T_AMPERSAND() => VALUE_SUB,
    T_ARYLEN()    => VALUE_ARRAY_LENGTH,
    );

my %declaration_to_flags =
  ( OP_MY()       => DECLARATION_MY,
    OP_OUR()      => DECLARATION_OUR,
    OP_STATE()    => DECLARATION_STATE,
    );

my %prec_assoc_bin =
  ( # T_ARROW()       => [ 2,  ASSOC_LEFT ],
    T_POWER()       => [ 4,  ASSOC_RIGHT, OP_POWER ],
    T_MATCH()       => [ 6,  ASSOC_LEFT,  OP_MATCH ],
    T_NOTMATCH()    => [ 6,  ASSOC_LEFT,  OP_NOT_MATCH ],
    T_STAR()        => [ 7,  ASSOC_LEFT,  OP_MULTIPLY ],
    T_SLASH()       => [ 7,  ASSOC_LEFT,  OP_DIVIDE ],
    T_PERCENT()     => [ 7,  ASSOC_LEFT,  OP_MODULUS ],
    T_SSTAR()       => [ 7,  ASSOC_LEFT,  OP_REPEAT ],
    T_PLUS()        => [ 8,  ASSOC_LEFT,  OP_ADD ],
    T_MINUS()       => [ 8,  ASSOC_LEFT,  OP_SUBTRACT ],
    T_DOT()         => [ 8,  ASSOC_LEFT,  OP_CONCATENATE ],
    T_OPAN()        => [ 11, ASSOC_NON,   OP_NUM_LT ],
    T_CLAN()        => [ 11, ASSOC_NON,   OP_NUM_GT ],
    T_LESSEQUAL()   => [ 11, ASSOC_NON,   OP_NUM_LE ],
    T_GREATEQUAL()  => [ 11, ASSOC_NON,   OP_NUM_GE ],
    T_SLESS()       => [ 11, ASSOC_NON,   OP_STR_LT ],
    T_SGREAT()      => [ 11, ASSOC_NON,   OP_STR_GT ],
    T_SLESSEQUAL()  => [ 11, ASSOC_NON,   OP_STR_LE ],
    T_SGREATEQUAL() => [ 11, ASSOC_NON,   OP_STR_GE ],
    T_EQUALEQUAL()  => [ 12, ASSOC_NON,   OP_NUM_EQ ],
    T_NOTEQUAL()    => [ 12, ASSOC_NON,   OP_NUM_NE ],
    T_CMP()         => [ 12, ASSOC_NON,   OP_NUM_CMP ],
    T_SEQUALEQUAL() => [ 12, ASSOC_NON,   OP_STR_EQ ],
    T_SNOTEQUAL()   => [ 12, ASSOC_NON,   OP_STR_NE ],
    T_SCMP()        => [ 12, ASSOC_NON,   OP_STR_CMP ],
    T_AMPERSAND()   => [ 13, ASSOC_LEFT,  OP_BIT_AND ],
    T_OR()          => [ 14, ASSOC_LEFT,  OP_BIT_OR ],
    T_XOR()         => [ 14, ASSOC_LEFT,  OP_BIT_XOR ],
    T_ANDAND()      => [ 15, ASSOC_LEFT,  OP_LOG_AND ],
    T_OROR()        => [ 16, ASSOC_LEFT,  OP_LOG_OR ],
    T_DOTDOT()      => [ 17, ASSOC_NON,   OP_DOT_DOT ],
    T_DOTDOTDOT()   => [ 17, ASSOC_NON,   OP_DOT_DOT_DOT ],
    T_INTERR()      => [ 18, ASSOC_RIGHT ], # ternary
    T_EQUAL()       => [ 19, ASSOC_RIGHT, OP_ASSIGN ],
    T_PLUSEQUAL()   => [ 19, ASSOC_RIGHT, OP_ADD_ASSIGN ],
    T_MINUSEQUAL()  => [ 19, ASSOC_RIGHT, OP_SUBTRACT_ASSIGN ],
    T_STAREQUAL()   => [ 19, ASSOC_RIGHT, OP_MULTIPLY_ASSIGN ],
    T_SLASHEQUAL()  => [ 19, ASSOC_RIGHT, OP_DIVIDE_ASSIGN ],
    T_COMMA()       => [ 20, ASSOC_LEFT ],
    # 21, list ops
    T_ANDANDLOW()   => [ 23, ASSOC_LEFT,  OP_LOG_AND ],
    T_ORORLOW()     => [ 24, ASSOC_LEFT,  OP_LOG_OR ],
    T_XORLOW()      => [ 24, ASSOC_LEFT,  OP_LOG_XOR ],
    T_COLON()       => [ 40, ASSOC_RIGHT ], # ternary, must be lowest,
    );

my %prec_assoc_un =
  ( T_PLUSPLUS()    => [ 3,  ASSOC_NON,   OP_PREINC ],
    T_MINUSMINUS()  => [ 3,  ASSOC_NON,   OP_PREDEC ],
    T_PLUS()        => [ 5,  ASSOC_RIGHT, OP_PLUS ],
    T_MINUS()       => [ 5,  ASSOC_RIGHT, OP_MINUS ],
    T_NOT()         => [ 5,  ASSOC_RIGHT, OP_LOG_NOT ],
    T_TILDE()       => [ 5,  ASSOC_RIGHT, OP_BIT_NOT ],
    T_BACKSLASH()   => [ 5,  ASSOC_RIGHT, OP_REFERENCE ],
    T_NOTLOW()      => [ 22, ASSOC_RIGHT, OP_LOG_NOT ],
    );

my %dereference_type =
  ( VALUE_SCALAR()       => OP_DEREFERENCE_SCALAR,
    VALUE_ARRAY()        => OP_DEREFERENCE_ARRAY,
    VALUE_HASH()         => OP_DEREFERENCE_HASH,
    VALUE_SUB()          => OP_DEREFERENCE_SUB,
    VALUE_GLOB()         => OP_DEREFERENCE_GLOB,
    VALUE_ARRAY_LENGTH() => OP_ARRAY_LENGTH,
    );

sub new {
    my( $class, $args ) = @_;
    my $self = $class->SUPER::new( $args );

    $self->_options( {} ) unless $self->_options;

    return $self;
}

sub set_option {
    my( $self, $option, $value ) = @_;

    if( $option eq 'dump-parse-tree' ) {
        $self->_options->{$option} = 1;
    }

    return 0;
}

sub parse_string {
    my( $self, $string, $package ) = @_;

    open my $fh, '<', \$string;

    $self->_package( $package );
    $self->parse_stream( $fh, '<string>' );
}

sub parse_file {
    my( $self, $file ) = @_;

    open my $fh, '<', $file or die "open '$file': $!";

    $self->_package( 'main' );
    $self->parse_stream( $fh, $file );
}

sub parse_stream {
    my( $self, $stream, $filename ) = @_;

    $self->{lexer} = Language::P::Lexer->new
                         ( { stream       => $stream,
                             file         => $filename,
                             symbol_table => $self->runtime->symbol_table,
                             } );
    $self->{_lexical_state} = [];
    $self->_parse;
}

sub _qualify {
    my( $self, $name, $type ) = @_;
    if( $type == T_FQ_ID ) {
        ( my $normalized = $name ) =~ s/^(?:::)?(?:main::)?//;
        return $normalized;
    }
    my $prefix = $self->_package eq 'main' ? '' : $self->_package . '::';
    return $prefix . $name;
}

sub _parse {
    my( $self ) = @_;

    my $dumper;
    if(    $self->_options->{'dump-parse-tree'}
        && -f $self->lexer->file ) {
        require Language::P::ParseTree::DumpYAML;
        ( my $outfile = $self->lexer->file ) =~ s/(\.\w+)?$/.pt/;
        open my $out, '>', $outfile || die "Can't open '$outfile': $!";
        my $dumpyml = Language::P::ParseTree::DumpYAML->new;
        $dumper = sub {
            print $out $dumpyml->dump( $_[0] );
        };
    }

    $self->_pending_lexicals( [] );
    $self->_lexicals( undef );
    $self->_enter_scope( 0, 1 ); # FIXME eval

    $self->generator->start_code_generation( { file_name => $self->lexer->file,
                                               } );
    while( my $line = _parse_line( $self ) ) {
        $dumper->( $line ) if $dumper;
        $self->generator->process( $line );
    }
    $self->_leave_scope;
    my $code = $self->generator->end_code_generation;

    return $code;
}

sub _enter_scope {
    my( $self, $is_sub, $top_level ) = @_;

    push @{$self->{_lexical_state}}, { package  => $self->_package,
                                       lexicals => $self->_lexicals,
                                       is_sub   => $is_sub,
                                       top_level=> $top_level,
                                       };
    if( $is_sub || $top_level ) {
        $self->{_lexical_state}[-1]{sub} = { labels  => {},
                                             jumps   => [],
                                             };
    } elsif( @{$self->{_lexical_state}} > 1 ) {
        $self->{_lexical_state}[-1]{sub} = $self->{_lexical_state}[-2]{sub};
    }
    $self->_lexicals( Language::P::Parser::Lexicals->new
                          ( { outer         => $self->_lexicals,
                              is_subroutine => $is_sub || 0,
                              top_level     => $top_level,
                              } ) );
}

sub _leave_scope {
    my( $self ) = @_;

    my $state = pop @{$self->{_lexical_state}};
    $self->_package( $state->{package} );
    $self->_lexicals( $state->{lexicals} );
    _patch_gotos( $self, $state ) if $state->{is_sub} || $state->{top_level};
}

sub _patch_gotos {
    my( $self, $state ) = @_;
    my $labels = $state->{sub}{labels};

    foreach my $goto ( @{$state->{sub}{jumps}} ) {
        if( $labels->{$goto->left} ) {
            $goto->set_attribute( 'target', $labels->{$goto->left}, 1 );
        }
    }
}

sub _syntax_error {
    my( $self, $token ) = @_;

    Carp::confess( sprintf "Unexpected token '%s' (%s) at %s:%d\n       ",
                           $token->[O_VALUE], $token->[O_TYPE],
                           $token->[O_POS][0], $token->[O_POS][1] );
}

sub _lex_token {
    my( $self, $type, $value, $expect ) = @_;
    my $token = $self->lexer->lex( $expect || X_NOTHING );

    return if !$value && !$type;

    if(    ( $type && $type != $token->[O_TYPE] )
        || ( $value && $value eq $token->[O_VALUE] ) ) {
        _syntax_error( $self, $token );
    }

    return $token;
}

sub _lex_semicolon {
    my( $self ) = @_;
    my $token = $self->lexer->lex;

    if( $token->[O_TYPE] == T_EOF || $token->[O_TYPE] == T_SEMICOLON ) {
        return;
    } elsif( $token->[O_TYPE] == T_CLBRK ) {
        $self->lexer->unlex( $token );
        return;
    }

    _syntax_error( $self, $token );
}

my %special_sub = map { $_ => 1 }
  ( qw(AUTOLOAD DESTROY BEGIN UNITCHECK CHECK INIT END) );

sub _parse_line {
    my( $self ) = @_;
    my $label = $self->lexer->peek( X_STATE );

    if( $label->[O_TYPE] != T_LABEL ) {
        return _parse_line_rest( $self, 1 );
    } else {
        _lex_token( $self, T_LABEL );
        my $statement =    _parse_line_rest( $self, 0 )
                        || Language::P::ParseTree::Empty->new;

        $statement->set_attribute( 'label', $label->[O_VALUE] );
        $self->_lexical_sub_state->{labels}{$label->[O_VALUE]} ||= $statement;

        return $statement;
    }
}

sub _parse_line_rest {
    my( $self, $no_empty ) = @_;
    my $token = $self->lexer->peek( X_STATE );
    my $tokidt = $token->[O_ID_TYPE];

    if( $token->[O_TYPE] == T_SEMICOLON ) {
        _lex_semicolon( $self );

        return $no_empty ? _parse_line_rest( $self, 1 ) : undef;
    } elsif( $token->[O_TYPE] == T_OPBRK ) {
        _lex_token( $self, T_OPBRK );

        return _parse_block_rest( $self, BLOCK_OPEN_SCOPE|BLOCK_BARE );
    } elsif( $token->[O_TYPE] == T_ID && is_keyword( $tokidt ) ) {
        if( $tokidt == KEY_SUB ) {
            return _parse_sub( $self, 1 | 2 );
        } elsif( $tokidt == KEY_IF || $tokidt == KEY_UNLESS ) {
            return _parse_cond( $self );
        } elsif( $tokidt == KEY_WHILE || $tokidt == KEY_UNTIL ) {
            return _parse_while( $self );
        } elsif( $tokidt == KEY_FOR || $tokidt == KEY_FOREACH ) {
            return _parse_for( $self );
        } elsif( $tokidt == KEY_PACKAGE ) {
            _lex_token( $self, T_ID );
            my $id = $self->lexer->lex_identifier( 0 );
            _lex_semicolon( $self );

            $self->_package( $id->[O_VALUE] );

            return Language::P::ParseTree::Package->new
                       ( { name => $id->[O_VALUE],
                           } );
        } elsif(    $tokidt == OP_MY
                 || $tokidt == OP_OUR
                 || $tokidt == OP_STATE
                 || $tokidt == OP_GOTO
                 || $tokidt == OP_LAST
                 || $tokidt == OP_NEXT
                 || $tokidt == OP_REDO
                 || $tokidt == KEY_LOCAL ) {
            return _parse_sideff( $self );
        }
    } elsif( $special_sub{$token->[O_VALUE]} ) {
        return _parse_sub( $self, 1, 1 );
    } else {
        return _parse_sideff( $self );
    }

    _syntax_error( $self, $token );
}

sub _add_pending_lexicals {
    my( $self ) = @_;

    # FIXME our() is different
    foreach my $lexical ( @{$self->_pending_lexicals} ) {
        $self->_lexicals->add_lexical( $lexical );
    }

    $self->_pending_lexicals( [] );
}

sub _parse_sub {
    my( $self, $flags, $no_sub_token ) = @_;
    _lex_token( $self, T_ID ) unless $no_sub_token;
    my $name = $self->lexer->lex_alphabetic_identifier( 0 );
    my $fqname = $name ? _qualify( $self, $name->[O_VALUE], $name->[O_ID_TYPE] ) : undef;

    # TODO prototypes
    if( $fqname ) {
        die "Syntax error: named sub '$fqname'" unless $flags & 1;

        my $next = $self->lexer->lex( X_OPERATOR );

        if( $next->[O_TYPE] == T_SEMICOLON ) {
            $self->generator->add_declaration( $fqname );

            return Language::P::ParseTree::SubroutineDeclaration->new
                       ( { name => $fqname,
                           } );
        } elsif( $next->[O_TYPE] != T_OPBRK ) {
            _syntax_error( $self, $next );
        }
    } else {
        _lex_token( $self, T_OPBRK );
        die 'Syntax error: anonymous sub' unless $flags & 2;
    }

    $self->_enter_scope( 1 );
    my $sub = $fqname ? Language::P::ParseTree::NamedSubroutine->new
                            ( { name     => $fqname,
                                } ) :
                        Language::P::ParseTree::AnonymousSubroutine->new;
    # add @_ to lexical scope
    $self->_lexicals->add_name( VALUE_ARRAY, '_' );

    my $block = _parse_block_rest( $self, BLOCK_IMPLICIT_RETURN );
    $sub->{lines} = $block->{lines}; # FIXME encapsulation
    $sub->set_parent_for_all_childs;
    $self->_leave_scope;

    # add a subroutine declaration, the generator might
    # not create it until later
    if( $fqname ) {
        $self->generator->add_declaration( $fqname );
    }

    return $sub;
}

sub _parse_cond {
    my( $self ) = @_;
    my $cond = _lex_token( $self, T_ID );

    _lex_token( $self, T_OPPAR );

    $self->_enter_scope;
    my $expr = _parse_expr( $self );
    $self->_add_pending_lexicals;

    _lex_token( $self, T_CLPAR );
    _lex_token( $self, T_OPBRK, undef, X_BLOCK );

    my $block = _parse_block_rest( $self, BLOCK_OPEN_SCOPE );

    my $if = Language::P::ParseTree::Conditional->new
                 ( { iftrues => [ Language::P::ParseTree::ConditionalBlock->new
                                      ( { block_type => $cond->[O_VALUE],
                                          condition  => $expr,
                                          block      => $block,
                                          } )
                                  ],
                     } );

    for(;;) {
        my $else = $self->lexer->peek( X_STATE );
        last if    $else->[O_TYPE] != T_ID
                || ( $else->[O_ID_TYPE] != KEY_ELSE && $else->[O_ID_TYPE] != KEY_ELSIF );
        _lex_token( $self );

        my $expr;
        if( $else->[O_ID_TYPE] == KEY_ELSIF ) {
            _lex_token( $self, T_OPPAR );
            $expr = _parse_expr( $self );
            _lex_token( $self, T_CLPAR );
        }
        _lex_token( $self, T_OPBRK, undef, X_BLOCK );
        my $block = _parse_block_rest( $self, BLOCK_OPEN_SCOPE );

        if( $expr ) {
            push @{$if->iftrues}, Language::P::ParseTree::ConditionalBlock->new
                                      ( { block_type => 'if',
                                          condition  => $expr,
                                          block      => $block,
                                          } )
        } else {
            # FIXME encapsulation
            $if->{iffalse} = Language::P::ParseTree::ConditionalBlock->new
                                      ( { block_type => 'else',
                                          condition  => undef,
                                          block      => $block,
                                          } );
        }
    }

    $if->set_parent_for_all_childs;
    $self->_leave_scope;

    return $if;
}

sub _parse_for {
    my( $self ) = @_;
    my $keyword = _lex_token( $self, T_ID );
    my $token = $self->lexer->lex( X_OPERATOR );
    my( $foreach_var, $foreach_expr );

    $self->_enter_scope;

    if( $token->[O_TYPE] == T_OPPAR ) {
        my $expr = _parse_expr( $self );
        my $sep = $self->lexer->lex( X_OPERATOR );

        if( $sep->[O_TYPE] == T_CLPAR ) {
            $foreach_var = _find_symbol( $self, VALUE_SCALAR, '_', T_FQ_ID );
            $foreach_expr = $expr;
        } elsif( $sep->[O_TYPE] == T_SEMICOLON ) {
            # C-style for
            $self->_add_pending_lexicals;

            my $cond = _parse_expr( $self );
            _lex_token( $self, T_SEMICOLON );
            $self->_add_pending_lexicals;

            my $incr = _parse_expr( $self );
            _lex_token( $self, T_CLPAR );
            $self->_add_pending_lexicals;

            _lex_token( $self, T_OPBRK, undef, X_BLOCK );
            my $block = _parse_block_rest( $self, BLOCK_OPEN_SCOPE );

            my $for = Language::P::ParseTree::For->new
                          ( { block_type  => 'for',
                              initializer => $expr,
                              condition   => $cond,
                              step        => $incr,
                              block       => $block,
                              } );

            $self->_leave_scope;

            return $for;
        } else {
            _syntax_error( $self, $sep );
        }
    } elsif( $token->[O_TYPE] == T_ID && (    $token->[O_ID_TYPE] == OP_MY
                                           || $token->[O_ID_TYPE] == OP_OUR
                                           || $token->[O_ID_TYPE] == OP_STATE ) ) {
        _lex_token( $self, T_DOLLAR );
        my $name = $self->lexer->lex_identifier( 0 );
        die "No name" unless $name;

        # FIXME our() variable refers to package it was declared in
        $foreach_var = Language::P::ParseTree::Symbol->new
                           ( { name    => $name->[O_VALUE],
                               sigil   => VALUE_SCALAR,
                               } );
        $foreach_var = _process_declaration( $self, $foreach_var,
                                             $token->[O_ID_TYPE] );
    } elsif( $token->[O_TYPE] == T_DOLLAR ) {
        my $id = $self->lexer->lex_identifier( 0 );
        $foreach_var = _find_symbol( $self, VALUE_SCALAR, $id->[O_VALUE], $id->[O_ID_TYPE] );
    } else {
        _syntax_error( $self, $token );
    }

    # if we get there it is not C-style for
    if( !$foreach_expr ) {
        _lex_token( $self, T_OPPAR );
        $foreach_expr = _parse_expr( $self );
        _lex_token( $self, T_CLPAR );
    }

    $self->_add_pending_lexicals;
    _lex_token( $self, T_OPBRK, undef, X_BLOCK );

    my $block = _parse_block_rest( $self, BLOCK_OPEN_SCOPE );
    my $continue = _parse_continue( $self );
    my $for = Language::P::ParseTree::Foreach->new
                  ( { expression => $foreach_expr,
                      block      => $block,
                      variable   => $foreach_var,
                      continue   => $continue,
                      } );

    $self->_leave_scope;

    return $for;
}

sub _parse_while {
    my( $self ) = @_;
    my $keyword = _lex_token( $self, T_ID );

    _lex_token( $self, T_OPPAR );

    $self->_enter_scope;
    my $expr = _parse_expr( $self );
    $self->_add_pending_lexicals;

    _lex_token( $self, T_CLPAR );
    _lex_token( $self, T_OPBRK, undef, X_BLOCK );

    my $block = _parse_block_rest( $self, BLOCK_OPEN_SCOPE );
    my $continue = _parse_continue( $self );
    my $while = Language::P::ParseTree::ConditionalLoop
                    ->new( { condition  => $expr,
                             block      => $block,
                             block_type => $keyword->[O_VALUE],
                             continue   => $continue,
                             } );

    $self->_leave_scope;

    return $while;
}

sub _parse_continue {
    my( $self ) = @_;
    my $token = $self->lexer->peek( X_STATE );
    return unless $token->[O_TYPE] == T_ID && $token->[O_ID_TYPE] == KEY_CONTINUE;

    _lex_token( $self, T_ID );
    _lex_token( $self, T_OPBRK, undef, X_BLOCK );

    return _parse_block_rest( $self, BLOCK_OPEN_SCOPE );
}

sub _parse_sideff {
    my( $self ) = @_;
    my $expr = _parse_expr( $self );
    my $keyword = $self->lexer->peek( X_TERM );

    if( $keyword->[O_TYPE] == T_ID && is_keyword( $keyword->[O_ID_TYPE] ) ) {
        my $keyidt = $keyword->[O_ID_TYPE];

        if( $keyidt == KEY_IF || $keyidt == KEY_UNLESS ) {
            _lex_token( $self, T_ID );
            my $cond = _parse_expr( $self );

            $expr = Language::P::ParseTree::Conditional->new
                        ( { iftrues => [ Language::P::ParseTree::ConditionalBlock->new
                                             ( { block_type => $keyword->[O_VALUE],
                                                 condition  => $cond,
                                                 block      => $expr,
                                                 } )
                                         ],
                            } );
        } elsif( $keyidt == KEY_WHILE || $keyidt == KEY_UNTIL ) {
            _lex_token( $self, T_ID );
            my $cond = _parse_expr( $self );

            $expr = Language::P::ParseTree::ConditionalLoop->new
                        ( { condition  => $cond,
                            block      => $expr,
                            block_type => $keyword->[O_VALUE],
                            } );
        } elsif( $keyidt == KEY_FOR || $keyidt == KEY_FOREACH ) {
            _lex_token( $self, T_ID );
            my $cond = _parse_expr( $self );

            $expr = Language::P::ParseTree::Foreach->new
                        ( { expression => $cond,
                            block      => $expr,
                            variable   => _find_symbol( $self, VALUE_SCALAR, '_', T_FQ_ID ),
                            } );
        }
    }

    _lex_semicolon( $self );
    $self->_add_pending_lexicals;

    return $expr;
}

sub _parse_expr {
    my( $self ) = @_;

    return _parse_term( $self, PREC_LOWEST );
}

sub _find_symbol {
    my( $self, $sigil, $name, $type ) = @_;

    if( $self->_in_declaration ) {
        return Language::P::ParseTree::Symbol->new
                   ( { name  => $name,
                       sigil => $sigil,
                       } );
    } elsif( $type == T_FQ_ID ) {
        return Language::P::ParseTree::Symbol->new
                   ( { name  => _qualify( $self, $name, $type ),
                       sigil => $sigil,
                       } );
    }

    my( $level, $lex ) = $self->_lexicals->find_name( $sigil . "\0" . $name );

    if( $lex ) {
        $lex->set_closed_over if $level > 0;

        return Language::P::ParseTree::LexicalSymbol->new
                   ( { declaration => $lex,
                       level       => $level,
                       } );
    }

    return Language::P::ParseTree::Symbol->new
               ( { name  => _qualify( $self, $name, $type ),
                   sigil => $sigil,
                   } );
}

sub _parse_maybe_subscript_rest {
    my( $self, $subscripted, $arrow_only ) = @_;
    my $next = $self->lexer->peek( X_OPERATOR );

    # array/hash element
    if( $next->[O_TYPE] == T_ARROW ) {
        _lex_token( $self, T_ARROW );
        my $bracket = $self->lexer->peek( X_OPERATOR );

        if(    $bracket->[O_TYPE] == T_OPPAR
            || $bracket->[O_TYPE] == T_OPSQ
            || $bracket->[O_TYPE] == T_OPBRK ) {
            return _parse_dereference_rest( $self, $subscripted, $bracket );
        } else {
            return _parse_maybe_direct_method_call( $self, $subscripted );
        }
    } elsif( $arrow_only ) {
        return $subscripted;
    } elsif(    $next->[O_TYPE] == T_OPPAR
             || $next->[O_TYPE] == T_OPSQ
             || $next->[O_TYPE] == T_OPBRK ) {
        return _parse_dereference_rest( $self, $subscripted, $next );
    } else {
        return $subscripted;
    }
}

sub _parse_indirect_function_call {
    my( $self, $subscripted, $with_arguments, $ampersand ) = @_;

    my $args;
    if( $with_arguments ) {
        _lex_token( $self, T_OPPAR );
        ( $args, undef ) = _parse_arglist( $self, PREC_LOWEST, 0, 0 );
        _lex_token( $self, T_CLPAR );
    }

    # $foo->() requires an additional dereference, while
    # &{...}(...) does not construct a reference but might need it
    if( !$subscripted->is_symbol || $subscripted->sigil != VALUE_SUB ) {
        $subscripted = Language::P::ParseTree::Dereference->new
                           ( { left => $subscripted,
                               op   => OP_DEREFERENCE_SUB,
                               } );
    }

    # treat &foo; separately from all other cases
    if( $ampersand && !$with_arguments ) {
        return Language::P::ParseTree::SpecialFunctionCall->new
                   ( { function    => $subscripted,
                       flags       => FLAG_IMPLICITARGUMENTS,
                       } );
    } else {
        return Language::P::ParseTree::FunctionCall->new
                   ( { function    => $subscripted,
                       arguments   => $args,
                       } );
    }
}

sub _parse_dereference_rest {
    my( $self, $subscripted, $bracket ) = @_;
    my $term;

    if( $bracket->[O_TYPE] == T_OPPAR ) {
        $term = _parse_indirect_function_call( $self, $subscripted, 1, 0 );
    } else {
        my $subscript = _parse_bracketed_expr( $self, $bracket->[O_TYPE], 0 );
        $term = Language::P::ParseTree::Subscript->new
                    ( { subscripted => $subscripted,
                        subscript   => $subscript,
                        type        => $bracket->[O_TYPE] == T_OPBRK ?
                                           VALUE_HASH : VALUE_ARRAY,
                        reference   => 1,
                        } );
    }

    return _parse_maybe_subscript_rest( $self, $term );
}

sub _parse_bracketed_expr {
    my( $self, $bracket, $allow_empty, $no_consume_opening ) = @_;
    my $close = $bracket == T_OPBRK ? T_CLBRK :
                $bracket == T_OPSQ  ? T_CLSQ :
                                      T_CLPAR;

    _lex_token( $self, $bracket ) unless $no_consume_opening;
    if( $allow_empty ) {
        my $next = $self->lexer->peek( X_TERM );
        if( $next->[O_TYPE] == $close ) {
            _lex_token( $self, $close );
            return undef;
        }
    }
    my $subscript = _parse_expr( $self );
    _lex_token( $self, $close );

    return $subscript;
}

sub _parse_maybe_indirect_method_call {
    my( $self, $op, $next ) = @_;
    my $indir = _parse_indirobj( $self, 1 );

    if( $indir ) {
        # if FH -> no method
        # proto FH -> no method
        # Foo $bar (?) -> no method
        # foo $bar -> method

        # print xxx -> no method, but print is handled before getting
        # there, since it is a non-overridable builtin

        # foo pack:: -> method

        # use Data::Dumper;
        # print Dumper( $indir ) . ' ' . Dumper( $next );

        my $args = _parse_term( $self, PREC_COMMA );
        if( $args ) {
            if( $args->isa( 'Language::P::ParseTree::List' ) ) {
	        $args = @{$args->expressions} ? $args->expressions : undef;
            } else {
                $args = [ $args ];
            }
        }
        $indir = Language::P::ParseTree::Constant->new
                     ( { flags => CONST_STRING,
                         value => $indir->[O_VALUE],
                         } )
            if ref( $indir ) eq 'ARRAY';
        my $term = Language::P::ParseTree::MethodCall->new
                       ( { invocant  => $indir,
                           method    => $op->[O_VALUE],
                           arguments => $args,
                           indirect  => 0,
                           } );

        return _parse_maybe_subscript_rest( $self, $term );
    }

    return Language::P::ParseTree::Constant->new
               ( { value => $op->[O_VALUE],
                   flags => CONST_STRING|STRING_BARE
                   } );
}

sub _parse_maybe_direct_method_call {
    my( $self, $invocant ) = @_;
    my $token = $self->lexer->lex( X_TERM );
    my( $method, $indirect );

    if( $token->[O_TYPE] == T_ID ) {
        ( $method, $indirect ) = ( $token->[O_VALUE], 0 );
    } elsif( $token->[O_TYPE] == T_DOLLAR ) {
        my $id = $self->lexer->lex_identifier( 0 );
        $method = _find_symbol( $self, VALUE_SCALAR, $id->[O_VALUE], $id->[O_ID_TYPE] );
        $indirect = 1;
    } else {
        _syntax_error( $self, $token );
    }

    my $oppar = $self->lexer->peek( X_OPERATOR );
    my $args;
    if( $oppar->[O_TYPE] == T_OPPAR ) {
        _lex_token( $self, T_OPPAR );
        ( $args ) = _parse_arglist( $self, PREC_LOWEST, 0, 0 );
        _lex_token( $self, T_CLPAR );
    }

    my $term = Language::P::ParseTree::MethodCall->new
                   ( { invocant  => $invocant,
                       method    => $method,
                       arguments => $args,
                       indirect  => $indirect,
                       } );

    return _parse_maybe_subscript_rest( $self, $term );
}

sub _parse_match {
    my( $self, $token ) = @_;

    if( $token->[O_RX_INTERPOLATED] ) {
        my $string = _parse_string_rest( $self, $token, 1 );
        my $match = Language::P::ParseTree::InterpolatedPattern->new
                        ( { string     => $string,
                            op         => $token->[O_VALUE],
                            flags      => $token->[O_RX_FLAGS],
                            } );

        return $match;
    } else {
        my $parts = Language::P::Parser::Regex->new
                        ( { generator   => $self->generator,
                            runtime     => $self->runtime,
                            interpolate => $token->[O_QS_INTERPOLATE],
                            } )->parse_string( $token->[O_QS_BUFFER] );
        my $match = Language::P::ParseTree::Pattern->new
                        ( { components => $parts,
                            op         => $token->[O_VALUE],
                            flags      => $token->[O_RX_FLAGS],
                            } );

        return $match;
    }
}

sub _parse_substitution {
    my( $self, $token ) = @_;
    my $match = _parse_match( $self, $token );

    my $replace;
    if( $match->flags & FLAG_RX_EVAL ) {
        local $self->{lexer} = Language::P::Lexer->new
                                   ( { string       => $token->[O_RX_SECOND_HALF]->[O_QS_BUFFER],
                                       symbol_table => $self->runtime->symbol_table,
                                       _heredoc_lexer => $self->lexer,
                                       } );
        $replace = _parse_block_rest( $self, BLOCK_OPEN_SCOPE, T_EOF );
    } else {
        $replace = _parse_string_rest( $self, $token->[O_RX_SECOND_HALF], 0 );
    }

    my $sub = Language::P::ParseTree::Substitution->new
                  ( { pattern     => $match,
                      replacement => $replace,
                      } );

    return $sub;
}

sub _parse_string_rest {
    my( $self, $token, $pattern ) = @_;
    my @values;
    local $self->{lexer} = Language::P::Lexer->new
                               ( { string       => $token->[O_QS_BUFFER],
                                   symbol_table => $self->runtime->symbol_table,
                                   } );

    $self->lexer->quote( { interpolate          => $token->[O_QS_INTERPOLATE],
                           pattern              => 0,
                           interpolated_pattern => $pattern,
                           } );
    for(;;) {
        my $value = $self->lexer->lex_quote;

        if( $value->[O_TYPE] == T_STRING ) {
            push @values, Language::P::ParseTree::Constant->new
                              ( { flags => CONST_STRING,
                                  value => $value->[O_VALUE],
                                  } );
        } elsif( $value->[O_TYPE] == T_EOF ) {
            last;
        } elsif( $value->[O_TYPE] == T_DOLLAR || $value->[O_TYPE] == T_AT ) {
            push @values, _parse_indirobj_maybe_subscripts( $self, $value );
        } else {
            _syntax_error( $self, $value );
        }
    }

    $self->lexer->quote( undef );

    my $string;
    if( @values == 1 && $values[0]->is_constant ) {
        $string = $values[0];
    } elsif( @values == 0 ) {
        $string = Language::P::ParseTree::Constant->new
                      ( { value => "",
                          flags => CONST_STRING,
                          } );
    } else {
        $string = Language::P::ParseTree::QuotedString->new
                      ( { components => \@values,
                           } );
    }

    my $quote = $token->[O_VALUE];
    if( $quote == OP_QL_QX ) {
        $string = Language::P::ParseTree::UnOp->new
                      ( { op   => OP_BACKTICK,
                          left => $string,
                          } );
    } elsif( $quote == OP_QL_QW ) {
        my @words = map Language::P::ParseTree::Constant->new
                            ( { value => $_,
                                flags => CONST_STRING,
                                } ),
                        split /[\s\r\n]+/, $string->value;

        $string = Language::P::ParseTree::List->new
                      ( { expressions => \@words,
                          } );
    }

    return $string;
}

sub _parse_term_terminal {
    my( $self, $token, $is_bind ) = @_;

    if( $token->[O_TYPE] == T_QUOTE ) {
        my $qstring = _parse_string_rest( $self, $token, 0 );

        if( $token->[O_VALUE] == OP_QL_LT ) {
            # simple scalar: readline, anything else: glob
            if(    $qstring->isa( 'Language::P::ParseTree::QuotedString' )
                && $#{$qstring->components} == 0
                && $qstring->components->[0]->is_symbol ) {
                return Language::P::ParseTree::Overridable
                           ->new( { function  => OP_READLINE,
                                    arguments => [ $qstring->components->[0] ] } );
            } elsif( $qstring->is_constant ) {
                if( $qstring->value =~ /^[a-zA-Z_]/ ) {
                    # FIXME simpler method, make lex_identifier static
                    my $lexer = Language::P::Lexer->new
                                    ( { string => $qstring->value } );
                    my $id = $lexer->lex_identifier( 0 );

                    if( $id && !length( ${$lexer->buffer} ) ) {
                        my $glob = Language::P::ParseTree::Symbol->new
                                       ( { name  => _qualify( $self, $id->[O_VALUE], $id->[O_ID_TYPE] ),
                                           sigil => VALUE_GLOB,
                                           } );
                        return Language::P::ParseTree::Overridable
                                   ->new( { function  => OP_READLINE,
                                            arguments => [ $glob ],
                                            } );
                    }
                }
                return Language::P::ParseTree::Glob
                           ->new( { arguments => [ $qstring ] } );
            } else {
                return Language::P::ParseTree::Glob
                           ->new( { arguments => [ $qstring ] } );
            }
        }

        return $qstring;
    } elsif( $token->[O_TYPE] == T_PATTERN ) {
        my $pattern;
        if( $token->[O_VALUE] == OP_QL_M || $token->[O_VALUE] == OP_QL_QR ) {
            $pattern = _parse_match( $self, $token );
        } elsif( $token->[O_VALUE] == OP_QL_S ) {
            $pattern = _parse_substitution( $self, $token );
        } else {
            die;
        }

        if( !$is_bind && $token->[O_VALUE] != OP_QL_QR ) {
            $pattern = Language::P::ParseTree::BinOp->new
                           ( { op    => OP_MATCH,
                               left  => _find_symbol( $self, VALUE_SCALAR, '_', T_FQ_ID ),
                               right => $pattern,
                               } );
        }

        return $pattern;
    } elsif( $token->[O_TYPE] == T_NUMBER ) {
        return Language::P::ParseTree::Constant->new
                   ( { value => $token->[O_VALUE],
                       flags => $token->[O_NUM_FLAGS]|CONST_NUMBER,
                       } );
    } elsif( $token->[O_TYPE] == T_PACKAGE ) {
        return Language::P::ParseTree::Constant->new
                   ( { value => $self->_package,
                       flags => CONST_STRING,
                       } );
    } elsif( $token->[O_TYPE] == T_STRING ) {
        return Language::P::ParseTree::Constant->new
                   ( { value => $token->[O_VALUE],
                       flags => CONST_STRING,
                       } );
    } elsif(    $token->[O_TYPE] == T_DOLLAR
             || $token->[O_TYPE] == T_AT
             || $token->[O_TYPE] == T_PERCENT
             || $token->[O_TYPE] == T_STAR
             || $token->[O_TYPE] == T_AMPERSAND
             || $token->[O_TYPE] == T_ARYLEN ) {
        return ( _parse_indirobj_maybe_subscripts( $self, $token ), 1 );
    } elsif(    $token->[O_TYPE] == T_ID ) {
        my $tokidt = $token->[O_ID_TYPE];

        if( !is_keyword( $token->[O_ID_TYPE] ) ) {
            return _parse_listop( $self, $token );
        } elsif(    $tokidt == OP_MY
                 || $tokidt == OP_OUR
                 || $tokidt == OP_STATE ) {
            return _parse_lexical( $self, $token->[O_ID_TYPE] );
        } elsif( $tokidt == KEY_SUB ) {
            return _parse_sub( $self, 2, 1 );
        } elsif(    $tokidt == OP_GOTO
                 || $tokidt == OP_LAST
                 || $tokidt == OP_NEXT
                 || $tokidt == OP_REDO ) {
            my $id = $self->lexer->lex;
            my $dest;
            if( $id->[O_TYPE] == T_ID && $id->[O_ID_TYPE] == T_ID ) {
                $dest = $id->[O_VALUE];
            } else {
                $self->lexer->unlex( $id );
                $dest = _parse_term( $self, PREC_LOWEST );
                if( $dest ) {
                    $dest = $dest->left
                        if $dest->isa( 'Language::P::ParseTree::Parentheses' );
                    $dest = $dest->value if $dest->is_constant;
                }
            }

            my $jump = Language::P::ParseTree::Jump->new
                           ( { op   => $tokidt,
                               left => $dest,
                               } );
            push @{$self->_lexical_state->[-1]{sub}{jumps}}, $jump
              if $tokidt == OP_GOTO && !ref( $dest );

            return $jump;
        } elsif( $tokidt == KEY_LOCAL ) {
            return Language::P::ParseTree::Local->new
                       ( { left => _parse_term_list_if_parens( $self, PREC_NAMED_UNOP ),
                           } );
        }
    } elsif( $token->[O_TYPE] == T_OPHASH ) {
        my $expr = _parse_bracketed_expr( $self, T_OPBRK, 1, 1 );

        return Language::P::ParseTree::ReferenceConstructor->new
                   ( { expression => $expr,
                       type       => VALUE_HASH,
                       } );
    } elsif( $token->[O_TYPE] == T_OPSQ ) {
        my $expr = _parse_bracketed_expr( $self, T_OPSQ, 1, 1 );

        return Language::P::ParseTree::ReferenceConstructor->new
                   ( { expression => $expr,
                       type       => VALUE_ARRAY,
                       } );
    }

    return undef;
}

sub _parse_term_terminal_maybe_subscripts {
    my( $self, $token, $is_bind ) = @_;
    my( $term, $no_subscr ) = _parse_term_terminal( $self, $token, $is_bind );

    return $term if $no_subscr || !$term;
    return _parse_maybe_subscript_rest( $self, $term, 1 );
}

sub _parse_indirobj_maybe_subscripts {
    my( $self, $token ) = @_;
    my $indir = _parse_indirobj( $self, 0 );
    my $sigil = $token_to_sigil{$token->[O_TYPE]};
    my $is_id = ref( $indir ) eq 'ARRAY' && $indir->[O_TYPE] == T_ID;

    # no subscripting/slicing possible for '%'
    if( $sigil == VALUE_HASH ) {
        return $is_id ? _find_symbol( $self, $sigil, $indir->[O_VALUE], $indir->[O_ID_TYPE] ) :
                         Language::P::ParseTree::Dereference->new
                             ( { left  => $indir,
                                 op    => OP_DEREFERENCE_HASH,
                                 } );
    }

    my $next = $self->lexer->peek( X_OPERATOR );

    if( $sigil == VALUE_SUB ) {
        my $deref = $is_id ? _find_symbol( $self, $sigil, $indir->[O_VALUE], $indir->[O_ID_TYPE] ) :
                             $indir;

        return _parse_indirect_function_call( $self, $deref,
                                              $next->[O_TYPE] == T_OPPAR, 1 );
    }

    # simplify the code below by resolving the symbol here, so a
    # dereference will be constructed below (probably an unary
    # operator would be more consistent)
    if( $sigil == VALUE_ARRAY_LENGTH && $is_id ) {
        $indir = _find_symbol( $self, VALUE_ARRAY, $indir->[O_VALUE], $indir->[O_ID_TYPE] );
        $is_id = 0;
    }

    if( $next->[O_TYPE] == T_ARROW ) {
        my $deref = $is_id ? _find_symbol( $self, $sigil, $indir->[O_VALUE], $indir->[O_ID_TYPE] ) :
                             Language::P::ParseTree::Dereference->new
                                 ( { left  => $indir,
                                     op    => $dereference_type{$sigil},
                                     } );

        return _parse_maybe_subscript_rest( $self, $deref );
    }

    my( $is_slice, $sym_sigil );
    if(    ( $sigil == VALUE_ARRAY || $sigil == VALUE_SCALAR )
        && ( $next->[O_TYPE] == T_OPSQ || $next->[O_TYPE] == T_OPBRK ) ) {
        $sym_sigil = $next->[O_TYPE] == T_OPBRK ? VALUE_HASH : VALUE_ARRAY;
        $is_slice = $sigil == VALUE_ARRAY;
    } elsif( $sigil == VALUE_GLOB && $next->[O_TYPE] == T_OPBRK ) {
        $sym_sigil = VALUE_GLOB;
    } else {
        return $is_id ? _find_symbol( $self, $sigil, $indir->[O_VALUE], $indir->[O_ID_TYPE] ) :
                         Language::P::ParseTree::Dereference->new
                             ( { left  => $indir,
                                 op    => $dereference_type{$sigil},
                                 } );
    }

    my $subscript = _parse_bracketed_expr( $self, $next->[O_TYPE], 0 );
    my $subscripted = $is_id ? _find_symbol( $self, $sym_sigil, $indir->[O_VALUE], $indir->[O_ID_TYPE] ) :
                               $indir;
    my $subscript_type = $next->[O_TYPE] == T_OPBRK ? VALUE_HASH : VALUE_ARRAY;

    if( $is_slice ) {
        return Language::P::ParseTree::Slice->new
                   ( { subscripted => $subscripted,
                       subscript   => $subscript,
                       type        => $subscript_type,
                       reference   => $is_id ? 0 : 1,
                       } );
    } else {
        my $term = Language::P::ParseTree::Subscript->new
                       ( { subscripted => $subscripted,
                           subscript   => $subscript,
                           type        => $subscript_type,
                           reference   => $is_id ? 0 : 1,
                           } );

        return _parse_maybe_subscript_rest( $self, $term );
    }
}

sub _parse_lexical {
    my( $self, $keyword ) = @_;

    die $keyword unless $keyword == OP_MY || $keyword == OP_OUR;

    local $self->{_in_declaration} = 1;
    my $term = _parse_term_list_if_parens( $self, PREC_NAMED_UNOP );

    return _process_declaration( $self, $term, $keyword );
}

sub _process_declaration {
    my( $self, $decl, $keyword ) = @_;

    if( $decl->isa( 'Language::P::ParseTree::List' ) ) {
        foreach my $e ( @{$decl->expressions} ) {
            $e = _process_declaration( $self, $e, $keyword );
        }

        return $decl;
    } elsif( $decl->isa( 'Language::P::ParseTree::Symbol' ) ) {
        my $decl = Language::P::ParseTree::LexicalDeclaration->new
                       ( { name    => $decl->name,
                           sigil   => $decl->sigil,
                           flags   => $declaration_to_flags{$keyword},
                           } );
        push @{$self->_pending_lexicals}, $decl;

        return $decl;
    } else {
        die 'Invalid node ', ref( $decl ), ' in declaration';
    }
}

sub _parse_term_p {
    my( $self, $prec, $token, $lookahead, $is_bind ) = @_;
    my $terminal = _parse_term_terminal_maybe_subscripts( $self, $token, $is_bind );

    return $terminal if $terminal && !$lookahead;

    if( $terminal ) {
        my $la = $self->lexer->peek( X_OPERATOR );
        my $binprec = $prec_assoc_bin{$la->[O_TYPE]};

        if( !$binprec || $binprec->[0] > $prec ) {
            return $terminal;
        } elsif( $la->[O_TYPE] == T_INTERR ) {
            _lex_token( $self, T_INTERR );
            return _parse_ternary( $self, PREC_TERNARY, $terminal );
        } elsif( $binprec ) {
            return _parse_term_n( $self, $binprec->[0],
                                  $terminal );
        } else {
            _syntax_error( $self, $la );
        }
    } elsif( $token->[O_TYPE] == T_FILETEST ) {
        return _parse_listop_like( $self, undef, 1,
                                   Language::P::ParseTree::Builtin->new
                                       ( { function => $token->[O_FT_OP],
                                           } ) );
    } elsif( my $p = $prec_assoc_un{$token->[O_TYPE]} ) {
        my $rest = _parse_term_n( $self, $p->[0] );

        return Language::P::ParseTree::UnOp->new
                   ( { op    => $p->[2],
                       left  => $rest,
                       } );
    } elsif( $token->[O_TYPE] == T_OPPAR ) {
        my $term = _parse_expr( $self );
        _lex_token( $self, T_CLPAR );

        if( !$term ) {
            # empty list
            return Language::P::ParseTree::List->new
                       ( { expressions => [],
                           } );
        } elsif( !$term->isa( 'Language::P::ParseTree::List' ) ) {
            # record that there were prentheses, unless it is a list
            return Language::P::ParseTree::Parentheses->new
                       ( { left => $term,
                           } );
        } else {
            return $term;
        }
    }

    return undef;
}

sub _parse_ternary {
    my( $self, $prec, $terminal ) = @_;

    my $iftrue = _parse_term_n( $self, PREC_TERNARY_COLON - 1 );
    _lex_token( $self, T_COLON );
    my $iffalse = _parse_term( $self, $prec );

    return Language::P::ParseTree::Ternary->new
               ( { condition => $terminal,
                   iftrue    => $iftrue,
                   iffalse   => $iffalse,
                   } );
}

sub _parse_term_n {
    my( $self, $prec, $terminal, $is_bind ) = @_;

    if( !$terminal ) {
        my $token = $self->lexer->lex( X_TERM );
        $terminal = _parse_term_p( $self, $prec, $token, undef, $is_bind );

        if( !$terminal ) {
            $self->lexer->unlex( $token );
            return undef;
        }
    }

    for(;;) {
        my $token = $self->lexer->lex( X_OPERATOR );

        if(    $token->[O_TYPE] == T_PLUSPLUS
            || $token->[O_TYPE] == T_MINUSMINUS ) {
            my $op = $token->[O_TYPE] == T_PLUSPLUS ? OP_POSTINC : OP_POSTDEC;
            $terminal = Language::P::ParseTree::UnOp->new
                            ( { op    => $op,
                                left  => $terminal,
                                } );
            $token = $self->lexer->lex( X_OPERATOR );
        }

        my $bin = $prec_assoc_bin{$token->[O_TYPE]};
        if( !$bin || $bin->[0] > $prec ) {
            $self->lexer->unlex( $token );
            last;
        } elsif( $token->[O_TYPE] == T_INTERR ) {
            $terminal = _parse_ternary( $self, PREC_TERNARY, $terminal );
        } else {
            # do not try to use colon as binary
            _syntax_error( $self, $token )
                if $token->[O_TYPE] == T_COLON;

            my $q = $bin->[1] == ASSOC_RIGHT ? $bin->[0] : $bin->[0] - 1;
            my $rterm = _parse_term_n( $self, $q, undef,
                                       (    $token->[O_TYPE] == T_MATCH
                                         || $token->[O_TYPE] == T_NOTMATCH ) );

            if( $token->[O_TYPE] == T_COMMA ) {
                if( $terminal->isa( 'Language::P::ParseTree::List' ) ) {
                    if( $rterm ) {
                        push @{$terminal->expressions}, $rterm;
                        $rterm->set_parent( $terminal );
                    }
                } else {
                    $terminal = Language::P::ParseTree::List->new
                        ( { expressions => [ $terminal, $rterm ? $rterm : () ],
                            } );
                }
            } else {
                $terminal = Language::P::ParseTree::BinOp->new
                                ( { op    => $bin->[2],
                                    left  => $terminal,
                                    right => $rterm,
                                    } );
            }
        }
    }

    return $terminal;
}

sub _parse_term {
    my( $self, $prec ) = @_;
    my $token = $self->lexer->lex( X_TERM );
    my $terminal = _parse_term_p( $self, $prec, $token, 1, 0 );

    if( $terminal ) {
        $terminal = _parse_term_n( $self, $prec, $terminal );

        return $terminal;
    }

    $self->lexer->unlex( $token );

    return undef;
}

sub _parse_term_list_if_parens {
    my( $self, $prec ) = @_;
    my $term = _parse_term( $self, $prec );

    if( $term->isa( 'Language::P::ParseTree::Parentheses' ) ) {
        return Language::P::ParseTree::List->new
                   ( { expressions => [ $term->left ],
                       } );
    }

    return $term;
}

sub _add_implicit_return {
    my( $line ) = @_;

    return $line unless $line->can_implicit_return;
    if( !$line->is_compound ) {
        return Language::P::ParseTree::Builtin->new
                   ( { arguments => [ $line ],
                       function  => OP_RETURN,
                       } );
    }

    # compound and can implicitly return
    if( $line->isa( 'Language::P::ParseTree::Block' ) && @{$line->lines} ) {
        $line->lines->[-1] = _add_implicit_return( $line->lines->[-1] );
    } elsif( $line->isa( 'Language::P::ParseTree::Conditional' ) ) {
        _add_implicit_return( $_ ) foreach @{$line->iftrues};
        _add_implicit_return( $line->iffalse ) if $line->iffalse;
    } elsif( $line->isa( 'Language::P::ParseTree::ConditionalBlock' ) ) {
        _add_implicit_return( $line->block )
    } else {
        Carp::confess( "Unhandled statement type: ", ref( $line ) );
    }

    return $line;
}

sub _parse_block_rest {
    my( $self, $flags, $end_token ) = @_;

    $end_token ||= T_CLBRK;
    $self->_enter_scope if $flags & BLOCK_OPEN_SCOPE;

    my @lines;
    for(;;) {
        my $token = $self->lexer->lex( X_STATE );
        if( $token->[O_TYPE] == $end_token ) {
            if( $flags & BLOCK_IMPLICIT_RETURN && @lines ) {
                for( my $i = $#lines; $i >= 0; --$i ) {
                    next if $lines[$i]->is_declaration;
                    $lines[$i] = _add_implicit_return( $lines[$i] );
                    last;
                }
            }

            $self->_leave_scope if $flags & BLOCK_OPEN_SCOPE;
            if( $flags & BLOCK_BARE ) {
                my $continue = _parse_continue( $self );
                return Language::P::ParseTree::BareBlock->new
                           ( { lines    => \@lines,
                               continue => $continue,
                               } );
            } else {
                return Language::P::ParseTree::Block->new
                           ( { lines => \@lines,
                               } );
            }
        } else {
            $self->lexer->unlex( $token );
            my $line = _parse_line( $self );

            push @lines, $line if $line; # skip empty satements
        }
    }
}

sub _parse_indirobj {
    my( $self, $allow_fail ) = @_;
    my $id = $self->lexer->lex_identifier( 0 );

    if( $id ) {
        return $id;
    }

    my $token = $self->lexer->lex( X_OPERATOR );

    if( $token->[O_TYPE] == T_OPBRK ) {
        my $block = _parse_block_rest( $self, BLOCK_OPEN_SCOPE );

        return $block;
    } elsif( $token->[O_TYPE] == T_DOLLAR ) {
        my $indir = _parse_indirobj( $self, 0 );

        if( ref( $indir ) eq 'ARRAY' && $indir->[O_TYPE] == T_ID ) {
            return _find_symbol( $self, VALUE_SCALAR, $indir->[O_VALUE], $indir->[O_ID_TYPE] );
        } else {
            return Language::P::ParseTree::Dereference->new
                       ( { left  => $indir,
                           op    => OP_DEREFERENCE_SCALAR,
                           } );
        }
    } elsif( $allow_fail ) {
        $self->lexer->unlex( $token );

        return undef;
    } else {
        _syntax_error( $self, $token );
    }
}

sub _declared_id {
    my( $self, $op ) = @_;
    my $call;
    my $opidt = $op->[O_ID_TYPE];

    if( is_overridable( $opidt ) ) {
        my $st = $self->runtime->symbol_table;

        if( $st->get_symbol( _qualify( $self, $op->[O_VALUE], $opidt ), '&' ) ) {
            die "Overriding '" . $op->[O_VALUE] . "' not implemented";
        }
        $call = Language::P::ParseTree::Overridable->new
                    ( { function  => $KEYWORD_TO_OP{$opidt},
                        } );

        return ( $call, 1 );
    } elsif( is_builtin( $opidt ) ) {
        $call = Language::P::ParseTree::Builtin->new
                    ( { function  => $KEYWORD_TO_OP{$opidt},
                        } );

        return ( $call, 1 );
    } else {
        my $st = $self->runtime->symbol_table;

        if( $st->get_symbol( _qualify( $self, $op->[O_VALUE], $opidt ), '&' ) ) {
            return ( undef, 1 );
        }
    }

    return ( undef, 0 );
}

sub _parse_listop {
    my( $self, $op ) = @_;
    my( $call, $declared ) = _declared_id( $self, $op );

    return _parse_listop_like( $self, $op, $declared, $call );
}

sub _parse_listop_like {
    my( $self, $op, $declared, $call ) = @_;
    my $proto = $call ? $call->parsing_prototype : undef;
    my $expect = !$proto                                         ? X_TERM :
                 $proto->[2] & (PROTO_FILEHANDLE|PROTO_INDIROBJ) ? X_REF :
                 $proto->[2] & (PROTO_BLOCK|PROTO_SUB)           ? X_BLOCK :
                                                                   X_TERM;
    my $next = $self->lexer->peek( $expect );
    my( $args, $fh );

    if( !$call || !$declared ) {
        my $st = $self->runtime->symbol_table;

        if( $next->[O_TYPE] == T_ARROW ) {
            _lex_token( $self, T_ARROW );
            my $la = $self->lexer->peek( X_OPERATOR );

            if( $la->[O_TYPE] == T_ID || $la->[O_TYPE] == T_DOLLAR ) {
                # here we are calling the method on a bareword
                my $invocant = Language::P::ParseTree::Constant->new
                                   ( { value => $op->[O_VALUE],
                                       flags => CONST_STRING,
                                       } );

                return _parse_maybe_direct_method_call( $self, $invocant );
            } elsif( $la->[O_TYPE] == T_OPPAR ) {
                # parsed as a normal sub call; go figure
                $next = $la;
            } else {
                _syntax_error( $self, $la );
            }
        } elsif( !$declared && $next->[O_TYPE] != T_OPPAR ) {
            # not a declared subroutine, nor followed by parenthesis
            # try to see if it is some sort of (indirect) method call
            return _parse_maybe_indirect_method_call( $self, $op, $next );
        }

        # foo Bar:: is always a method call
        if(    $next->[O_TYPE] == T_ID
            && $st->get_package( $next->[O_VALUE] ) ) {
            return _parse_maybe_indirect_method_call( $self, $op, $next );
        }

        my $symbol = Language::P::ParseTree::Symbol->new
                         ( { name  => _qualify( $self, $op->[O_VALUE], $op->[O_ID_TYPE] ),
                             sigil => VALUE_SUB,
                             } );
        $call = Language::P::ParseTree::FunctionCall->new
                    ( { function  => $symbol,
                        arguments => undef,
                        } );
        $proto = $call->parsing_prototype;
    }

    if( $next->[O_TYPE] == T_OPPAR ) {
        _lex_token( $self, T_OPPAR );
        ( $args, $fh ) = _parse_arglist( $self, PREC_LOWEST, 0, $proto->[2] );
        _lex_token( $self, T_CLPAR );
    } elsif( $proto->[1] == 1 ) {
        ( $args, undef ) = _parse_arglist( $self, PREC_NAMED_UNOP, 1, $proto->[2] );
    } elsif( $proto->[1] != 0 ) {
        Carp::confess( "Undeclared identifier '" . $op->[O_VALUE] . "'" )
            unless $declared;
        ( $args, $fh ) = _parse_arglist( $self, PREC_COMMA, 0, $proto->[2] );
    }

    # FIXME avoid reconstructing the call?
    if( $proto->[2] & (PROTO_INDIROBJ|PROTO_FILEHANDLE) ) {
        $call = Language::P::ParseTree::BuiltinIndirect->new
                    ( { function  => $KEYWORD_TO_OP{$op->[O_ID_TYPE]},
                        arguments => $args,
                        indirect  => $fh,
                        } );
    } elsif( $args ) {
        # FIXME encapsulation
        $call->{arguments} = $args;
        $_->set_parent( $call ) foreach @$args;
    }

    _apply_prototype( $self, $call );

    return $call;
}

sub _apply_prototype {
    my( $self, $call ) = @_;
    my $proto = $call->parsing_prototype;
    my $args = $call->arguments || [];

    if( @$args < $proto->[0] ) {
        die "Too few arguments for call";
    }
    if( $proto->[1] != -1 && @$args > $proto->[1] ) {
        die "Too many arguments for call";
    }

    foreach my $i ( 3 .. $#$proto ) {
        last if $i - 3 > $#$args;
        my $proto_char = $proto->[$i];
        my $term = $args->[$i - 3];

        # defined/exists &foo
        if( $proto_char & PROTO_AMPER ) {
            if(    $term->isa( 'Language::P::ParseTree::SpecialFunctionCall' )
                && $term->flags & FLAG_IMPLICITARGUMENTS ) {
                $args->[$i - 3] = $term->function;
            }
        }
        if( $proto_char & PROTO_MAKE_GLOB && $term->is_bareword ) {
            $args->[$i - 3] = Language::P::ParseTree::Symbol->new
                                  ( { name  => $term->value,
                                      sigil => VALUE_GLOB,
                                      } );
        }
    }
}

sub _parse_arglist {
    my( $self, $prec, $is_unary, $proto_char ) = @_;
    my $indirect_term = $proto_char & (PROTO_INDIROBJ|PROTO_FILEHANDLE);
    my $la = $self->lexer->peek( $indirect_term ? X_REF : X_TERM );
    my $term_prec = $prec > PREC_LISTEXPR ? PREC_LISTEXPR : $prec;

    my $term;
    if( $indirect_term ) {
        if( $la->[O_TYPE] == T_OPBRK ) {
            $term = _parse_indirobj( $self, 0 );
        } elsif(    $proto_char & PROTO_FILEHANDLE
                 && $la->[O_TYPE] == T_ID
                 && $la->[O_ID_TYPE] == T_ID ) {
            # check if it is a declared id
            my $declared = $self->runtime->symbol_table
                ->get_symbol( _qualify( $self, $la->[O_VALUE], $la->[O_ID_TYPE] ), '&' );
            # look ahead one more token
            _lex_token( $self );
            my $la2 = $self->lexer->peek( X_TERM );

            # approximate what would happen in Perl LALR parser
            my $tt = $la2->[O_TYPE];
            if( $declared ) {
                $self->lexer->unlex( $la );
                $indirect_term = 0;
            } elsif(    $prec_assoc_bin{$tt}
                     && !$prec_assoc_un{$tt}
                     && $tt != T_STAR
                     && $tt != T_PERCENT
                     && $tt != T_DOLLAR
                     && $tt != T_AMPERSAND
                     ) {
                $self->lexer->unlex( $la );
                $indirect_term = 0;
            } elsif( $tt == T_ID && is_id( $la2->[O_ID_TYPE] ) ) {
                $self->lexer->unlex( $la );
                $indirect_term = 0;
            } else {
                $term = Language::P::ParseTree::Symbol->new
                            ( { name  => $la->[O_VALUE],
                                sigil => VALUE_GLOB,
                                } );
            }
        } else {
            $term = _parse_term( $self, $term_prec );

            if( !$term ) {
                $indirect_term = 0;
            } elsif(    !( $term->is_symbol && $term->sigil == VALUE_SCALAR )
                     && !$term->isa( 'Language::P::ParseTree::Block' ) ) {
                $indirect_term = 0;
            }
        }
    } elsif(    $proto_char & (PROTO_BLOCK|PROTO_SUB)
             && $la->[O_TYPE] == T_OPBRK ) {
        _lex_token( $self );
        $term = _parse_block_rest( $self, BLOCK_OPEN_SCOPE );
    }

    $term ||= _parse_term( $self, $term_prec );

    return unless $term;
    return [ $term ] if $is_unary;

    if( $indirect_term ) {
        my $la = $self->lexer->peek( X_TERM );

        if( $la->[O_TYPE] != T_COMMA ) {
            my $args = _parse_arglist( $self, $prec, 0, 0 );

            if( !$args && $term->is_symbol && $term->sigil == VALUE_SCALAR ) {
                return ( [ $term ] );
            } else {
                return ( $args, $term );
            }
        }
    }

    $term = _parse_term_n( $self, $prec, $term, 0 );

    return $term && $term->isa( 'Language::P::ParseTree::List' ) ?
               $term->expressions : [ $term ];
}

1;
