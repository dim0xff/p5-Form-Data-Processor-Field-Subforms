use strict;
use warnings;

use lib 't/lib';

use Test::Most;

package Subform::F0 {
    use Form::Data::Processor::Moose;
    extends 'Form::Data::Processor::Form::Config';

    has '+config' => (
        default => sub {
            {
                fields => [
                    {
                        name     => 'text',
                        type     => 'Text',
                        required => 1,
                    },
                    {
                        name     => 'number',
                        type     => 'Number',
                        required => 1,
                    },
                    {
                        name     => 'list',
                        type     => 'List::Single',
                        options  => [ 'O1', 'O2', 'O3' ],
                        required => 1,
                    },
                ],
            };
        }
    );
};


package Subform::F1 {
    use Form::Data::Processor::Moose;
    extends 'Form::Data::Processor::Form::Config';

    has '+config' => (
        default => sub {
            {
                #<<<
                fields => [
                    {
                        name     => 'text',
                        type     => 'Text',
                        required => 1,
                    },
                    {
                        name     => 'compound',
                        type     => 'Compound',
                        required => 1,
                    },
                        {
                            name     => 'compound.text',
                            type     => 'Text',
                            required => 0,
                        },
                        {
                            name     => 'compound.compound',
                            type     => 'Compound',
                            required => 0,
                        },
                            {
                                name     => 'compound.compound.text',
                                type     => 'Text',
                                required => 0,
                            },
                        {
                            name     => 'compound.repeatable',
                            type     => 'Repeatable',
                            required => 1
                        },
                            {
                                name     => 'compound.repeatable.text',
                                type     => 'Text',
                                required => 1
                            },
                            {
                                name    => 'compound.repeatable.list',
                                type    => 'List',
                                options => [ 'O1', 'O2', 'O3' ]
                            },
                            {
                                name    => 'compound.repeatable.compound',
                                type    => 'Compound',
                            },
                                {
                                    name    => 'compound.repeatable.compound.int',
                                    type    => 'Number::Int',
                                },
                                {
                                    name    => 'compound.repeatable.compound.float',
                                    type    => 'Number::Float',
                                },
                ],
                #>>>
            };
        }
    );
};

package Form {
    use Form::Data::Processor::Moose;
    extends 'Form::Data::Processor::Form';
    with 'Form::Data::Processor::TraitFor::Form::DumpErrors';

    has_field validator => (
        type    => 'List::Single',
        options => [ 'F0', 'F1', 'F2' ],
    );

    has_field data => (
        type           => 'Subforms',
        form_namespace => 'Subform',
        name_field     => 'validator',
    );
};


package main {
    local $SIG{__WARN__} = sub {};

    my $form = Form->new;

    subtest ready => sub {
        is_deeply(
            [
                map +{ $_->[0] => ref $_->[1] },
                sort { $a->[0] cmp $b->[0] }
                    $form->field('data')->_all_subforms
            ],
            [ { F0 => 'Subform::F0' }, { F1 => 'Subform::F1' } ],
            'Subform are ready'
        );

        is_deeply(
            $form->field('validator')->options,
            [
                { value => 'F0' },
                { value => 'F1' },
                { value => 'F2', disabled => 1 },
            ],
            'Validator option is disabled for non exist subform'
        );
    };

    subtest validate => sub {
        for ( 1 .. 2 ) {
            ok(
                !$form->process(
                    {
                        data => {
                            text     => {},
                            compound => {
                                text       => [],
                                repeatable => [
                                    (
                                        {
                                            list     => [ '1O', '2O' ],
                                            text     => {},
                                            compound => {
                                                int   => 1.23,
                                                float => 'abc',
                                            }
                                        }
                                    ) x 2,
                                    []
                                ],
                            }
                        },
                        validator => 'F1',
                    }
                ),
                "Process with error ($_)"
            );

            #<<<
            is_deeply(
                $form->dump_errors,
                {
                    'data.text' => ['Field value is not a valid text'],
                    'data.compound.text' => ['Field value is not a valid text'],

                    'data.compound.repeatable.0.list' => ['Value is not allowed'],
                    'data.compound.repeatable.0.text' => ['Field value is not a valid text'],
                    'data.compound.repeatable.0.compound.int' => ['Field value is not a valid integer number'],
                    'data.compound.repeatable.0.compound.float' => ['Field value is not a valid number'],

                    'data.compound.repeatable.1.list' => ['Value is not allowed'],
                    'data.compound.repeatable.1.text' => ['Field value is not a valid text'],
                    'data.compound.repeatable.1.compound.int' => ['Field value is not a valid integer number'],
                    'data.compound.repeatable.1.compound.float' => ['Field value is not a valid number'],

                    'data.compound.repeatable.2' => ['Field is invalid'],
                },
                "Error messages ($_)"
            );
            #>>>
        }

        for ( 1 .. 2 ) {
            ok(
                $form->process(
                    {
                        data => {
                            text     => 'The text',
                            compound => {
                                text       => 'The text',
                                repeatable => [
                                    {
                                        list     => [ 'O1', 'O2' ],
                                        text     => 'The text',
                                        compound => {
                                            int   => 1,
                                            float => 1.23,
                                        }
                                    },
                                ],
                            }
                        },
                        validator => 'F1',
                    }
                ),
                "Form processed ($_)"
            );

            is_deeply(
                $form->result,
                {
                    data => {
                        text     => 'The text',
                        compound => {
                            text       => 'The text',
                            repeatable => [
                                {
                                    list     => [ 'O1', 'O2' ],
                                    text     => 'The text',
                                    compound => {
                                        int   => 1,
                                        float => 1.23,
                                    }
                                },
                            ],
                        }
                    },
                    validator => 'F1',
                },
                "Result #$_"
            );
        }
    };

    subtest clone => sub {
        my $clone = $form->clone;

        ok( !$clone->field('data')->has_subform, 'Subform is not loaded' );

        ok( !$clone->process( { data => { text => [] }, validator => 'F1' } ),
            'Clone validated with error' );

        ok( $form->validated, 'And original is fine' );
    };

    done_testing();
};
