#!perl

use utf8;
use strict;
use warnings;

BEGIN { $ENV{DBIX_CONFIG_DIR} = "t" };

use File::Spec::Functions qw/catfile catdir/;
use lib catdir(qw/t lib/);
use Text::Amuse::Compile::Utils qw/read_file write_file/;
use AmuseWikiFarm::Utils::Amuse qw/from_json/;
use AmuseWiki::Tests qw/create_site/;
use AmuseWikiFarm::Schema;
use Test::More tests => 13;
use Data::Dumper;
use Path::Tiny;
use Test::WWW::Mechanize::Catalyst;
use DateTime;

my $site_id = '0catsort0';
my $schema = AmuseWikiFarm::Schema->connect('amuse');
my ($site);
unless ($site = $schema->resultset('Site')->find($site_id)) {
    $site = create_site($schema, $site_id);
    $site->update({
                   secure_site => 0,
                   epub => 1,
                  });
    foreach my $i (0..20) {
        my $pubdate = DateTime->now->subtract(days => $i + 10)->ymd;
        if ($i == 7) {
            $pubdate = DateTime->now->subtract(days => $i + 100)->ymd;
        }
        elsif ($i == 3) {
            $pubdate = DateTime->now->ymd;
        }
          
        my ($rev) = $site->create_new_text({ uri => "my-title-$i",
                                             title => 'Title #' .  $i,
                                             teaser => ($i % 2 ? "This is the preview for $i" : ''),
                                             author => "Author $i",
                                             SORTauthors => "common; author-$i; author-two-$i",
                                             SORTtopics => "common; topic-$i; topic-two-$i",
                                             pubdate => $pubdate,
                                             lang => 'en' }, 'text');
        my $cover = catfile(qw/t files shot.png/);
        if ($i % 2) {
            my $got = $rev->add_attachment($cover);
            $rev->edit("#cover $got->{attachment}\n" . $rev->muse_body);
        }
        $rev->edit("#customheader xxx\n" . $rev->muse_body . "\n\nFULL TEXT HERE\n");
        $rev->commit_version;
        $rev->publish_text;
    }
}
my $mech = Test::WWW::Mechanize::Catalyst->new(catalyst_app => 'AmuseWikiFarm',
                                               host => $site->canonical);

my $titles = $site->categories->by_type_and_uri(qw/topic common/)->titles;
is_deeply([$titles->available_sortings ],
          [{
            'label' => 'By title A-Z',
            'priority' => 1,
            'name' => 'title_asc'
           },
           {
            'name' => 'title_desc',
            'priority' => 2,
            'label' => 'By title Z-A'
           },
           {
            'priority' => 3,
            'name' => 'pubdate_desc',
            'label' => 'Newer first'
           },
           {
            'label' => 'Older first',
            'name' => 'pubdate_asc',
            'priority' => 4
           }]);

my %expected = (
                title_asc => 'my-title-0',
                title_desc => 'my-title-9',
                pubdate_asc => 'my-title-7',
                pubdate_desc => 'my-title-3',
               );
foreach my $sorting ($titles->available_sortings) {
    my $order_by = $sorting->{name};
    diag "$order_by $sorting->{label}";
    my $found = $site->titles->order_by($order_by)->first;
    is $found->uri, $expected{$order_by},
      "$order_by $sorting->{label} is $expected{$order_by} " . $found->pubdate->ymd;
}

foreach my $sorting ($site->titles->available_sortings) {
    my $order_by = $sorting->{name};
    diag "$order_by $sorting->{label}";
    foreach my $type (qw/topic author/) {
        my $found = $site->categories->by_type_and_uri($type, 'common')->titles->order_by($order_by)->first;
        is $found->uri, $expected{$order_by},
          "$order_by $sorting->{label} is $expected{$order_by} (from $type category) " . $found->pubdate->ymd;
    }
}
