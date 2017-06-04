package Form::Data::Processor::Field::Subforms;

# ABSTRACT: use forms like subfields

use Form::Data::Processor::Moose 0.5.0;
use namespace::autoclean;

extends 'Form::Data::Processor::Field';

has form_namespace => (
    is       => 'rw',
    isa      => 'Str',
    required => 1,
);

has name_field => (
    is  => 'rw',
    isa => 'Str',
);

has single_subform => (
    is  => 'rw',
    isa => 'Bool',
);

has subform_name => (
    is  => 'rw',
    isa => 'Str',
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


sub BUILD {
    my $self = shift;

    if ( $self->single_subform ) {
        die '"subform_name" must be provided on "single_subform" mode'
            unless $self->subform_name;
    }
    else {
        die '"name_field" must be provided' unless $self->name_field;
    }
}


sub _set_parent_fields_errors {
    my $self = shift;

    return unless $_[0];
    return unless $self->can('parent') && $self->has_parent;

    $self->parent->has_fields_errors(1);
}


before ready => sub {
    my $self = shift;

    for my $name ( $self->get_available_subforms ) {

        my $module = $self->form_namespace . '::' . $name->{value};
        my ( $loaded, $loading_error ) = Class::Load::try_load_class($module);

        if ($loaded) {
            my $subform = $module->new( parent => $self );
            $self->add_subform( $name->{value} => $subform );
        }
        else {
            $name->{disabled} = 1;

            my $msg
                = __PACKAGE__ . ": loading '$module' failed: $loading_error";

            if ( $self->single_subform ) {
                die $msg;
            }
            else {
                warn $msg;
            }
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

after generate_full_name => sub {
    my $self = shift;

    $_->[1]->generate_full_name for $self->_all_subforms;
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

sub internal_validation {
    my $self = shift;

    return if $self->has_errors || !$self->has_value || !defined $self->value;

    my $subform_name = $self->get_subform_name or return $self->clear_value;

    my $subform = $self->subform( $self->get_subform($subform_name) )
        or die "No such subform for '$subform_name'";

    $subform->params( $self->value );
    $subform->init_input( $subform->params );
    $subform->validate_fields;

    if ( !$subform->validated ) {
        $self->has_fields_errors(1);

        $self->add_error($_) for $subform->all_errors;
    }
}

sub get_available_subforms {
    my $self = shift;

    if ( $self->single_subform ) {
        return { value => $self->subform_name };
    }
    else {
        return @{ $self->parent->field( $self->name_field )->options };
    }
}

sub get_subform_name {
    my $self = shift;

    if ( $self->single_subform ) {
        return $self->subform_name;
    }
    else {
        return $self->parent->field( $self->name_field )->result;
    }
}

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


    #
    # Multi-subform mode
    # Dynamicaly load and validate data basing on `method` field value

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


    # ... and later

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


    #
    # Single-subform mode
    #

    package Shipping::ByOurStore {
        use Form::Data::Processor::Moose;
        extends 'Form::Data::Processor::Form';

        has_field method_data => (
            type           => 'Subforms',
            form_namespace => 'Shipping',
            single_subform => 1,
            subform_name   => 'ByOurStore',
        );
    }


    # ... and later

    my $form = Shipping::ByOurStore->new;
    $form->process(
        {
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
via L</form_namespace> and field (L</name_field>). If some field option fires
error, while class for this option is being tried to load, then this option is marked
"disabled". Loading uses next notation: C<form_namespace>::C<name_field option value>.

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

=item Required (when L</single_subform> is C<false>)

=back

Field name for L<Form::Data::Processor::Field::List::Single> field from C<parent>.

B<Notice:> field in C<parent> must be defined I<before> current field.


=attr single_subform

=over 4

=item Type: Bool

=back

When C<true> then use single-subform mode (see L</SYNOPSIS> for info).


=attr subform_name

=over 4

=item Type: Str

=item Required (when L</single_subform> is C<true>)

=back

Subform name which will be used to create validation subform.


=attr subform

Current validating subform.

B<Notice:> normally is being set by Form::Data::Processor internals.
