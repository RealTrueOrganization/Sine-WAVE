#!/usr/bin/perl

use strict;
#use warnings;

use Getopt::Long;
use POSIX;

#
# The Bangsplat Non-Realtime Software Synthesizer
# (AKA sineWAVE.pl)
# version 1.3
#
#
# created ??? (probably February 2009)
# modified 2017-02-07
#

my ( $output_param, $channel_param, $samplerate_param, $samplesize_param );
my ( $duration_param, $frequency_param, $level_param, $level_coef );
my ( $adsr_param, @envelope_list, $attack, $decay, $sustain, $release );
my ( $attack_samples, $decay_samples, $release_samples );
my ( $attack_coef, $decay_coef, $release_coef );
my ( $decay_range, $decay_percentage );
my ( $release_range, $release_percentage );
my ( @frequency_list, $list_length, $num_frequencies );
my ( $debug_param, $help_param, $version_param );
my ( $raw_size, $file_size, $buffer, $bytes_written );
my ( $num_samples, @sample_array, @normalized_array );
my ( $freq, $coef, $fp_sample, $quant_sample, $quant_string );
my $bytes_per_sample;
my $peak_sample_value = 0.0;
my $wav_header;
my $result;
my $frequency_file;

my $twopi = 2.0 * 3.141592653589793;

# subroutines

# generate_wav_header()
# 
# right now, we are getting the values we need (channels, sample rate/size)
# from global variables, but we should probably consider making them parameters
sub generate_wav_header {
	my ( $chunk_size, $sub_chunk_1_size, $audio_format, $num_channels );
	my ( $sample_rate, $byte_rate, $block_align, $bits_per_sample );
	
	$raw_size = $num_samples * ( $samplesize_param / 8 ) * $channel_param;
	
	my $wav_header = "RIFF";
	$chunk_size = $raw_size + 36;
	$wav_header .= pack( 'L', $chunk_size );
	
	# calculate the header values
	$sub_chunk_1_size = 16;
	# 	subChunk1Size is always 18 in Forge WAV files
	# 	 but as far as I can tell, it only needs to be 16
	# 	 why the two pad bytes?
	$audio_format = 1;
	$num_channels = $channel_param;
	$sample_rate = $samplerate_param;
	$bits_per_sample = $samplesize_param;
	$block_align = ceil( $num_channels * int( $bits_per_sample / 8 ) );
	$byte_rate = $sample_rate * $block_align;
	
	# sub chunk 1
	$wav_header .= "WAVE";
	$wav_header .= "fmt ";
	$wav_header .= pack( 'L', $sub_chunk_1_size );
	$wav_header .= pack( 'S', $audio_format );
	$wav_header .= pack( 'S', $num_channels );
	$wav_header .= pack( 'L', $sample_rate );
	$wav_header .= pack( 'L', $byte_rate );
	$wav_header .= pack( 'S', $block_align );
	$wav_header .= pack( 'S', $bits_per_sample );
	
	# data chunk header
	$wav_header .= "data";
	$wav_header .= pack( 'L', $raw_size );
	
	if ( $debug_param ) { print "generate_wav_header: $wav_header\n";}
	
	return( $wav_header );
}


# main

# parse the input parameters
GetOptions(	'output|o=s'		=> \$output_param,
		'channels|c=i'		=> \$channel_param,
		'samplerate|s=i'	=> \$samplerate_param,
		'samplesize|b=i'	=> \$samplesize_param,
		'frequency|osc|f=s'	=> \$frequency_param,
		'duration|d=f'		=> \$duration_param,
		'adsr|env=s'		=> \$adsr_param,
		'level|amp|l=f'		=> \$level_param,
		'debug'			=> \$debug_param,
		'version'		=> \$version_param,
		'help|?'		=> \$help_param );

if ( $debug_param ) {
	print "DEBUG";
	print "\tInput Parameters:\n";
	print "\t\toutput_param: $output_param\n";
	print "\t\tchannel_param: $channel_param\n";
	print "\t\tsamplerate_param: $samplerate_param\n";
	print "\t\tsamplesize_param: $samplesize_param\n";
	print "\t\tfrequency_param: $frequency_param\n";
	print "\t\tduration_param: $duration_param\n";
	print "\t\tadsr_param: $adsr_param\n";
	print "\t\tlevel_param: $level_param\n";
	print "\t\tdebug_param: $debug_param\n";
	print "\t\tversion_param: $version_param\n";
	print "\t\thelp_param: $help_param\n";
	print "\n";
}

# parameter processing
if ( $help_param ) {
	print "sineWAVE.pl\n";
	print "version 1.3\n";
	print "\n";
	print "Input Parameters:\n";
	print "\t--output|-o <output_filename>\n";
	print "\t--channels|-c [1|2] (currently mono only)\n";
	print "\t--samplesize|-b [16|24] (bit depth, default: 24)\n";
	print "\t--samplerate|-s <sampling_rate> (default: 96000)\n";
	print "\t--frequency|-f comma-separated frequency/coefficient list\n";
	print "\t\tor file name of comma-separated frequency/coefficient list\n";
	print "\t--duration|-d <duration> (in seconds, default: 1)\n";
	print "\t--adsr|--env <envelope>\n";
	print "\t--level|-l <level> normalize to this peak level\n";
	exit;
}
if ( $version_param ) { die "sineWAVE version 1.3\n"; }		# --version
if ( $output_param eq undef ) { die "Please specify output file\n"; }
if ( $frequency_param eq undef ) { die "Please specify a frequency list\n"; }
if ( $channel_param eq undef ) { $channel_param = 1; }
if ( $samplerate_param eq undef ) { $samplerate_param = 96000; }
if ( $samplesize_param eq undef ) { $samplesize_param = 24; }
if ( $duration_param eq undef ) { $duration_param = 1.0; }
$bytes_per_sample = int( $samplesize_param / 8 );
if ( $level_param eq undef ) { $level_param = 1.0; }
if ( $level_param > 1.0 ) { $level_param = 1.0; }
if ( $level_param < 0.0 ) { $level_param = 1.0; }

###
# allow two options for --frequency
# if $output_param has only one item,
# 	treat it as a text file containing the frequency/coefficient list
# if $output_param has two or more items,
# 	treat it as we currently do - parse out a comma-delimited list
# if $output_param eq undef,
# 	error out (as above)
###

# process the frequency list
@frequency_list = split( /,/, $frequency_param );
# $list_length = $#frequency_list + 1;
$list_length = scalar @frequency_list;
### check length here?
### if @frequency_list has only one item
### 	try to open a file with the name
### 	read in the contents of the file
### 	and place it in @frequency_list
if ( $list_length eq 1 ) {
	# only one item was provided
	# assume this is a file name that contains the frequency list
	if ( $debug_param ) {
		print "DEBUG: trying to open frequency list file @frequency_list[0]\n";
	}
	$frequency_file = @frequency_list[0];
	if ( $debug_param ) {
		print "DEBUG: frequency_file: $frequency_file\n";
	}
	# open the file
	open( FREQ_FILE, "<", $frequency_file ) or die "Can't open frequency list file\n";
	# how big is the file?
	my $frequency_file_size = -s FREQ_FILE;
	if ( $debug_param ) {
		print "DEBUG: frequency_file_size: $frequency_file_size\n";
	}
	# read the file into $frequency_param;
	$result = read( FREQ_FILE, $frequency_param, $frequency_file_size );
	if ( $result eq undef ) { die "Error reading input file $frequency_file\n"; }
	if ( $result eq 0 ) { print "WARNING: Input file is 0 bytes\n"; }
	chomp( $frequency_param );
	# close the file
	close( FREQ_FILE );
	if ( $debug_param ) {
		print "DEBUG: frequency list file contents:\n*****$frequency_param*****\n";
	}
	# repeat "@frequency_list = split( /,/, $frequency_param )" from above
	@frequency_list = split( /,/, $frequency_param );
	# repeat "$list_length = scalar @frequency_list" from above
	$list_length = scalar @frequency_list;
	if ( $debug_param) {
		print "DEBUG: frequency list file list length = $list_length\n";
	}
	# now check to make sure we actually got something
	if ( $list_length < 2 ) { die "Please specify a frequency list or file\n"; }
}
###
$num_frequencies = $list_length / 2;
if ( $debug_param ) {
	print "DEBUG";
	print "\tFrequency list is $list_length items:\n";
	for ( my $i = 0; $i < $list_length; $i++ ) {
		print "\t\tItem $i: $frequency_list[$i]\n";
	}
	print "\tnum_frequencies: $num_frequencies\n";
	for ( my $i = 0; $i < $num_frequencies; $i++ ) {
		print "\t\tfrequency: $frequency_list[$i*2] Hz * $frequency_list[$i*2+1]\n";
	}
	print "\n";
}
## I should probably be doing some range checking on the frequency/coef values
## as long as they're real numbers, everything should be good
## how do I check for non-numerical values in a scalar?

# process the envelope
if ( $adsr_param ne undef ) {
	@envelope_list = split( /,/, $adsr_param );
	$attack = $envelope_list[0];
	$decay = $envelope_list[1];
	$sustain = $envelope_list[2];
	$release = $envelope_list[3];
	if ( $attack + $decay + $release > 1.0 ) { die "Invalid ADSR values: A+S+R cannot exceed 1.0\n"; }
	if ( $sustain > 1.0 ) { $sustain = 1.0; }
}

if ( $debug_param ) {
	print "DEBUG";
	print "\tProcessed Parameters:\n";
	print "\t\toutput_param: $output_param\n";
	print "\t\tchannel_param: $channel_param\n";
	print "\t\tsamplerate_param: $samplerate_param\n";
	print "\t\tsamplesize_param: $samplesize_param\n";
	print "\t\tfrequency_param: $frequency_param\n";
	print "\t\tduration_param: $duration_param\n";
	print "\t\tadsr_param: $adsr_param\n";
	print "\t\tlevel_param: $level_param\n";
	print "\t\tdebug_param: $debug_param\n";
	print "\t\tversion_param: $version_param\n";
	print "\t\thelp_param: $help_param\n";
	print "\n";
}

# figure out how many samples we need
$num_samples = $samplerate_param * $duration_param;
if ( $debug_param ) { print "DEBUG\tnumsamples: $num_samples\n\n"; }

# set the size of the arrays
$#sample_array = $num_samples;
$#normalized_array = $num_samples;

if ( $debug_param ) { print "DEBUG\tArray size: $#sample_array\n\n"; }

# initialize sample array
if ( $debug_param ) { print "DEBUG\tInitializing sample array\n"; }
for ( my $n = 0; $n < $num_samples; $n++ ) { $sample_array[$n] = 0.0; }
if ( $debug_param ) { print "DEBUG\tDone initializing sample array\n\n"; }


## Do the Synthesis

# calculate the samples
for ( my $n = 0; $n < $num_samples; $n++ ) {
	for ( my $f = 0; $f < $num_frequencies; $f++ ) {
		# get a frequency and coefficient from the frequency list
		$freq = $frequency_list[$f*2];
		$coef = $frequency_list[$f*2+1];
		
		# do the math for each sample frequency/coefficient pair
		$fp_sample = $coef * ( sin( $twopi * ( $n / $samplerate_param ) * $freq ) );
		if ( $debug_param ) { print "DEBUG\tSample $n, frequency $freq, coef $coef: $fp_sample\n"; }
		
		# add the value to $sample_array[$n]
		$sample_array[$n] += $fp_sample;
	}
}
if ( $debug_param ) { print "\n"; }


## ADSR Envelope Generator
if ( $adsr_param ne undef ) {
	$attack_samples = int( $attack * $num_samples );
	$decay_samples = int( $decay * $num_samples );
	$release_samples = int( $release * $num_samples );

	if ( $debug_param ) {
		print "DEBUG";
		print "\tADSR Envelop Generator\n";
		print "\tattack_samples: $attack_samples\n";
		print "\tdecay_samples: $decay_samples\n";
		print "\trelease_samples: $release_samples\n\n";
	}

	# Attack
	# over range of 0..attack_samples, multiply each sample by a coef ranging from 0..1
	# should I implement a non-linear attack?
	$attack_coef = 0.0;
	for ( my $n = 0; $n < $attack_samples; $n++ ) {
		$attack_coef = ( $n / $attack_samples );
		if ( $debug_param ) { print "DEBUG\tattack $n: $attack_coef\n"; }
		$sample_array[$n] *= $attack_coef;
	}

	# Decay
	# from sample (attack_samples+1) to (attack_samples+1+decay_samples)
	# multiply by a coef ranging from 1..sustain
	$decay_range = 1.0 - $sustain;
	$decay_percentage = 0.0;
	$decay_coef = 0.0;
	for ( my $n = $attack_samples; $n < $attack_samples + $decay_samples; $n++ ) {
		$decay_percentage = ( $n - $attack_samples ) / $decay_samples;
		$decay_coef = 1.0 - ( $decay_range * $decay_percentage );
		if ( $debug_param ) { print "DEBUG\tdecay $n: $decay_coef\n"; }
		$sample_array[$n] *= $decay_coef;
	}

	# Sustain
	for ( my $n = ( $attack_samples + $decay_samples ); $n < ( $num_samples - $release_samples ); $n++ ) {
		$sample_array[$n] *= $sustain;
	}

	# Release
	# from end of sustain range to end of clip,
	# multiply by a coef ranging from sustain..0
	$release_coef = $sustain;
	$release_percentage = 0.0;
	for ( my $n = ( $num_samples - $release_samples ); $n < $num_samples; $n++ ) {
		$release_percentage = ( $n - ($num_samples - $release_samples ) ) / $release_samples;
		$release_coef = $sustain - ( $sustain * $release_percentage );
		$sample_array[$n] *= $release_coef;
	}
}


## "VCA"
## (Normalize the array)

# find the largest absolute sample value
for ( my $n = 0; $n < $num_samples; $n++ ) {
	$fp_sample = abs( $sample_array[$n] );
	if ( $fp_sample > $peak_sample_value ) { $peak_sample_value = $fp_sample; }
}
if ( $debug_param ) {
	print "DEBUG";
	print "\tPeak sample value: $peak_sample_value\n";
	print "\n";
}

# initialize the normalized sample array
if ( $debug_param ) { print "DEBUG\tInitializing normalized sample array\n"; }
for ( my $n = 0; $n < $num_samples; $n++ ) { $normalized_array[$n] = 0.0; }
if ( $debug_param ) { print "DEBUG\tDone initializing normalized sample array\n\n"; }

$level_coef = $level_param / $peak_sample_value;

# normalize the samples
if ( $debug_param ) { print "DEBUG\tNormalizing sample array\n"; }
for ( my $n = 0; $n < $num_samples; $n++ ) {
	$normalized_array[$n] = $sample_array[$n] * $level_coef;
}
if ( $debug_param ) { print "DEBUG\tFinished normalizing sample array\n\n"; }

if ( $debug_param) {
	for ( my $n = 0; $n < $num_samples; $n++ ) {
		print "DEBUG\tNormalized sample $n: $normalized_array[$n]\n";
	}
}

# open/create output file
open ( WAV_FILE, ">", $output_param )
	or die "ERROR: failed to open file $output_param\n";
binmode( WAV_FILE );	# set to binary mode

# generate WAVE header
my $buffer = generate_wav_header();
if ( $debug_param ) { print "DEBUG\tWAVE header:$buffer\n\n"; }

print WAV_FILE $buffer
	or die "ERROR: failed to write WAVE header";

# output sample data
for ( my $n = 0; $n < $num_samples; $n++ ) {
	$quant_sample = int( $normalized_array[$n] * ( ( ( 2 ** $samplesize_param ) / 2 ) - 1 ) );
	if ( $debug_param ) { print "DEBUG\tQuantized sample $n: $quant_sample\n"; }

	$quant_string = substr( pack( 'l', $quant_sample ), 0, $bytes_per_sample );
	print WAV_FILE $quant_string;
}

close( WAV_FILE );
