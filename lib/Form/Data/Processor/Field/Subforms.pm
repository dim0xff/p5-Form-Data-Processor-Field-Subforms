package Form::Data::Processor::Field::Subforms;

# ABSTRACT: use forms like subfields

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

    my $subform_name = $self->parent->field( $self->name_field )->value;

    if ( !$subform_name ) {
        $self->clear_value;
        return;
    }

    # Value to List::Single could be passed as array and as scalar.
    # Get the scalar value!
    $subform_name = $subform_name->[0] if ref $subform_name eq 'ARRAY';

    my $subform = $self->subform( $self->get_subform($subform_name) )
        or die "No such subform for '$subform_name'";

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

=head1 SYNOPSIS

    package Shipping::Free {
        use Form::Data::Processor::Moose;
        extends 'Form::Data::Processor::Form';

        has_field available_hours => (...);
    };

    package Shipping::ByOurStore {
        use Form::Data::Processor::Moose;
        extends 'Form::Data::Processor::Form';

        has_field cost_per_order   => (...);
        has_field cost_per_product => (...);
        has_field handling_fee     => (...);
    };

    package Shipping::USPS {
        use Form::Data::Processor::Moose;
        extends 'Form::Data::Processor::Form';

        has_field package_size            => (...);
        has_field domestic_mail_type      => (...);
        has_field international_mail_type => (...);
    };


    package Shipping {
        use Form::Data::Processor::Moose;
        extends 'Form::Data::Processor::Form';

        has_field method => (
            type    => 'List::Single',
            options => [ 'Free', 'ByOurStore', 'USPS' ]
        );

        has_field method_data => (
            type           => 'Subforms',
            form_namespace => 'Shipping',
            name_field     => 'method',
        );
    }


    # ...
    # And later
    #

    my $form = Shipping->new;
    $form->process(
        {
            method      => 'ByOurStore',
            method_data => {
                cost_per_order   => 10.00,
                cost_per_product => 0.50,
                handling_fee     => 3.00,
            },
        }
    ) or do {
        if ( $form->field('method_data.handling_fee')->has_errors ) {
            die "Incorrect handling fee:", $form->field('method_data.handling_fee')->all_errors;
        }

        ...
    };

=head1 DESCRIPTION

This add ability to use some forms like subfields in current form.
To determine which "subform" will be used, it uses result from
L<Form::Data::Processor::Field::List::Single> field.

Before field is L<Form::Data::Processor::Field/ready> it tries to load all classes
via L</form_namespace> and field (L</name_field>). If some field option is fire
error, while class for this option is being tried loading, then this options mark
as disabled.
Loading uses next notation: C<form_namespace>::C<name_field option value>.

On validating, input params will be passed to L</subform> to validate.

Implement methods, which screen the same methods on child form:

=over 4

=item all_error_fields

=item all_fields

=item error_fields

=item field

=item subfield

=back


=attr form_namespace

=over 4

=item Type: Str

=item Required

=back

Name space for subform loading.


=attr name_field

=over 4

=item Type: Str

=item Required

=back

Field name for L<Form::Data::Processor::Field::List::Single> field from C<parent>.

B<Notice:> field in C<parent> must be defined I<before> current field.

=attr subform

Current validating subform.

B<Notice:> normally is being set by Form::Data::Processor internals.
