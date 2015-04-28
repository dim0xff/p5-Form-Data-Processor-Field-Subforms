package Form::Data::Processor::Field::Subforms;

# ABSTRACT: use forms like fields

use Form::Data::Processor::Moose;
use namespace::autoclean;

extends 'Form::Data::Processor::Field';

has form_namespace => (
    is       => 'rw',
    isa      => 'Str',
    required => 1,
);

has name_field => (
    is       => 'rw',
    isa      => 'Str',
    required => 1,
);

has _subforms => (
    is      => 'ro',
    isa     => 'HashRef',
    traits  => ['Hash'],
    default => sub { {} },
    handles => {
        add_subform    => 'set',
        get_subform    => 'get',
        clear_subforms => 'clear',
        _all_subforms  => 'kv',
    }
);

has subform => (
    is        => 'rw',
    predicate => 'has_subform',
    clearer   => '_clear_subform',
);

has has_fields_errors => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
    trigger => \&_set_parent_fields_errors,
);

sub _set_parent_fields_errors {
    my $self = shift;

    return unless $_[0];
    return unless $self->can('parent') && $self->has_parent;

    $self->parent->has_fields_errors(1);
}


before ready => sub {
    my $self = shift;

    my $name_field = $self->parent->field( $self->name_field );

    for my $name ( @{ $name_field->options } ) {

        my $module = $self->form_namespace . '::' . $name->{value};
        my ( $loaded, $loading_error ) = Class::Load::try_load_class($module);

        if ($loaded) {
            my $subform = $module->new( parent => $self );
            $self->add_subform( $name->{value} => $subform );
        }
        else {
            $name->{disabled} = 1;

            warn __PACKAGE__ . ": loading '$module' failed: $loading_error";
        }
    }
};


after clear_errors => sub {
    my $self = shift;

    $self->subform->clear_errors if $self->has_subform;
    $self->has_fields_errors(0);
};

before reset => sub {
    my $self = shift;

    return if $self->not_resettable || !$self->has_subform;

    $self->subform->reset_fields;
};

before clear_value => sub {
    my $self = shift;

    if ( $self->has_subform ) {
        $self->subform->clear_params;

        for my $field ( $self->subform->all_fields ) {
            $field->clear_value if $field->has_value;
        }
    }

    $self->_clear_subform;
};


around clone => sub {
    my $orig = shift;
    my $self = shift;

    my %subforms = map { $_->[0] => $_->[1]->clone } $self->_all_subforms;


    my $clone = $self->$orig( _subforms => \%subforms, @_ );

    $_->parent($clone) for values %subforms;

    $clone->clear_errors;
    $clone->reset;
    $clone->clear_value;

    return $clone;
};

around validate => sub {
    my $orig = shift;
    my $self = shift;

    $self->$orig(@_);

    return if $self->has_errors || !$self->has_value || !defined $self->value;

    my $subform_name = $self->parent->field( $self->name_field )->result;

    if ( !$subform_name ) {
        $self->clear_value;
        return;
    }

    my $subform = $self->subform( $self->get_subform($subform_name) );

    $subform->params( $self->value );
    $subform->init_input( $subform->params );
    $subform->validate_fields;

    if ( !$subform->validated ) {
        $self->has_fields_errors(1);

        $self->add_error($_) for $subform->all_errors;
    }
};

sub _result {
    my $self = shift;

    return unless $self->has_subform;
    return $self->subform->result;
}

around has_errors => sub {
    my $orig = shift;
    my $self = shift;

    return 1 if $self->has_fields_errors;
    return $self->$orig;
};


# Add wrappers to subform
for my $sub ( 'error_fields', 'all_error_fields', 'field', 'subfield',
    'all_fields' )
{
    __PACKAGE__->meta->add_method(
        $sub => sub {
            my $self = shift;

            return unless $self->has_subform;
            return $self->subform->$sub(@_);
        }
    );
}

__PACKAGE__->meta->make_immutable;

1;

__END__
