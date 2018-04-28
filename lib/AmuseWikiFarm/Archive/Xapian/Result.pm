package AmuseWikiFarm::Archive::Xapian::Result;

use utf8;
use strict;
use warnings;
use Moo;
use Types::Standard qw/Int Maybe Object HashRef ArrayRef InstanceOf Str Bool/;
use JSON::MaybeXS;
use AmuseWikiFarm::Log::Contextual;
use Data::Page;
use DateTime;
use namespace::clean;

has pager => (is => 'ro',
              default => sub { Data::Page->new },
              isa => InstanceOf['Data::Page']);

has max_categories => (is => 'ro',
                       default => sub { 30 },
                       isa => Int);

has matches => (is => 'ro',
                default => sub { [] },
                isa => ArrayRef[HashRef]);

has facets => (is => 'ro',
               default => sub { +{} },
               isa => HashRef[ArrayRef[HashRef]]);

has selections => (is => 'ro',
                   default => sub { +{} },
                   isa => HashRef[HashRef]);

has site => (is => 'ro',
             isa => Maybe[Object]);

has lh => (is => 'ro',
           isa => Maybe[Object]);

has show_deferred => (is => 'ro',
                      isa => Bool,
                      default => sub { 0 });

has authors => (is => 'lazy');

has topics => (is => 'lazy');

has dates => (is => 'lazy');

has pubdates => (is => 'lazy');

has num_pages => (is => 'lazy');

has text_types => (is => 'lazy');

has error => (is => 'ro', isa => Maybe[Str]);

sub facet_tokens {
    my $self = shift;
    return [] if $self->error;
    my $lh = $self->lh;
    unless ($lh) {
        log_error { "Facet tokens called without the LH token, aborting" };
        return;
    }
    my @out = ({
                label => $lh->loc('Topics'),
                facets => $self->topics,
                name => 'filter_topic',
               },
               {
                label => $lh->loc('Authors'),
                facets => $self->authors,
                name => 'filter_author',
               },
               {
                label => $lh->loc('Date'),
                facets => $self->dates,
                name => 'filter_date',
               },
               {
                label => $lh->loc('Document type'),
                facets => $self->text_types,
                name => 'filter_qualification',
               },
               {
                label => $lh->loc('Published on this site'),
                facets => $self->pubdates,
                name => 'filter_pubdate',
               },
               {
                label => $lh->loc('Number of pages'),
                facets => $self->num_pages,
                name => 'filter_pages',
               });
    my $selections = $self->selections;
    foreach my $block (@out) {
        foreach my $facet (@{$block->{facets}}) {
            $facet->{active} = $selections->{$block->{name}}->{$facet->{value}};
        }
    }
    return \@out;
}

sub _build_authors {
    my $self = shift;
    my $list = $self->unpack_json_facets($self->facets->{author});
    $self->_add_category_labels($list);
    return $list;
}

sub _add_category_labels {
    my ($self, $list) = @_;
    my $site = $self->site or return;
    my @uris;
    foreach my $i (@$list) {
        my $uri = (split(/\//, $i->{value}))[-1];
        push @uris, $uri;
    }
    my $map = $site->categories->by_uri(\@uris)->full_uri_name_mapping_hashref;
    foreach my $i (@$list) {
        if (my $label = $map->{$i->{value}}) {
            $i->{label} = $label;
        }
    }
}

sub _build_topics {
    my $self = shift;
    my $list = $self->unpack_json_facets($self->facets->{topic});
    $self->_add_category_labels($list);
    if (my $lh = $self->lh) {
        foreach my $i (@$list) {
            $i->{label} = $lh->loc($i->{label});
        }
    }
    return $list;
}

sub _build_dates {
    my $self = shift;
    my $list = $self->facets->{date};
    foreach my $i (@$list) {
        # these are decades, actually
        $i->{label} = $i->{value} . '-' . ($i->{value} + 9);
    }
    return [ sort  { $a->{value} <=> $b->{value} } @$list ];

}

sub _build_pubdates {
    my $self = shift;
    my $list = $self->facets->{pubdate};
    my %years;
    my $now = time();
    foreach my $epoch (@$list) {
        if ($now > $epoch->{value}) {
            my $date = DateTime->from_epoch(epoch => $epoch->{value});
            $years{$date->year} += $epoch->{count};
        }
    }
    my @out;
    foreach my $y (keys %years) {
        push @out, { value => $y, label => $y, count => $years{$y} };
    }
    Dlog_debug { "pudates became is $_" } \@out;
    return \@out;
}

sub _build_num_pages {
    my $self = shift;
    my $list = $self->facets->{pages};
    foreach my $i (@$list) {
        $i->{label} = $i->{value};
    }
    return [ sort { _first_number($a->{value}) <=> _first_number($b->{value}) } @$list ];
}

sub _first_number {
    my $str = shift;
    if ($str =~ m/([1-9][0-9]*)/) {
        return $1;
    }
    else {
        return 0;
    }
}

sub _build_text_types {
    my $self = shift;
    my $list = $self->facets->{qualification};
    if (my $lh = $self->lh) {
        foreach my $i (@$list) {
            # loc('book'), loc('article')
            $i->{label} = $lh->loc($i->{value});
        }
    }
    return [ sort  { $a->{value} cmp $b->{value} } @$list ];
}



=head2 unpack_json_facets [INTERNAL]

This is horrid, but there is no multivalue and subclassing MatchSpy
leads to a beautiful segmentation fault (core dumped)

=cut

sub unpack_json_facets {
    my ($self, $arrayref) = @_;
    if ($arrayref) {
        my @raw = @$arrayref;
        my %out;
        while (@raw) {
            my $record = shift @raw;
            my @values = @{decode_json($record->{value})};
            my $count = $record->{count};
            foreach my $v (@values) {
                $out{$v} += $count;
            }
        }
        my @out = sort { $b->{count} <=> $a->{count} || $a->{value} cmp $b->{value} }
          map { +{ value => $_, count => $out{$_} } }
          keys %out;
        splice(@out, $self->max_categories);
        return \@out;
    }
    return undef;
}

sub texts {
    my ($self) = @_;
    return [] if $self->error;
    if (my $site = $self->site) {
        my @out = map { AmuseWikiFarm::Archive::Xapian::Result::Text->new($_->{pagedata}) } @{$self->matches};
        return \@out;
    }
    else {
        log_error { "Site object was not provided, cannot output a list of texts" };
        return;
    }
}

sub json_output {
    my $self = shift;
    my @out;
    if (my $texts = $self->texts) {
        my $base = $self->site->canonical_url;
        @out = map { +{
                       title => $_->title,
                       author => $_->author,
                       url => $base . $_->full_uri,
                       text_type => $_->text_qualification,
                       pages => $_->pages_estimated,
                      } } @$texts;
    }
    return \@out;
}

1;
