#!/usr/bin/env ruby
# vim: set ai ts=2 sw=2:

require 'date'
require 'ostruct'
require 'rexml/document'

# TODO break into libraries and utilities

def OpenStruct.nested(hash)
	OpenStruct.new(hash.inject({}) {|r,p|
		r[p[0]] = p[1].kind_of?(Hash) ? OpenStruct.nested(p[1]) : p[1]; r
	})
end

def ffsinfo(dev)
	IO.popen "ffsinfo -l 1 #{dev}" do |io|
		kw = {}
		stack = []
		io.each_line do |line|
			case line
			when /^#/
			when /^=+ START (.*) =+$/
				stack.push kw
				case io.readline
				when /^# (\d+)@(\S+): (\S+) (\S+)/
					kw = kw[$4] = {}
				end
			when /^=+ END (.*) =+$/
				kw = stack.pop
			when /^(\S+)[^"]+\s+"(.*)"$/ # string
				kw[$1] = $2
			when /^(\S+).*\]\S+(.+)/ # array
				kw[$1] = $2.split.map {|i| Integer i }
			when /^(\S+).*\s(.+)$/ # int
				kw[$1] = Integer $2
			end
		end
		OpenStruct.nested kw
	end
end

class GEOM
	# TODO follow @ref
	# TODO convert to hash with inject
	include REXML
	def initialize
		@gmesh = REXML::Document.new `sysctl -b kern.geom.confxml`.strip
	end
	def provider(name)
		Obj.new XPath.first(@gmesh, '//provider[name=$name]', nil, 'name' => name)
	end
	private
	class Obj
		def initialize(node)
			@node = node
		end
		def method_missing(m, *args, &block)
			# XXX child = REXML::XPath.first(@node, '$m', nil, 'm' => m)
			child = REXML::XPath.first(@node, m.to_s)
			if child.has_elements? then
				Obj.new child
			else
				begin
					Integer child.text
				rescue ArgumentError
					child.text
				end
			end
		end
	end
end

$gmesh = GEOM.new

class FSInfo
	# underlying device (geom name)
	attr_reader :dev
	# current mount point
	attr_reader :mountpoint
	# sector size of geom provider
	attr_reader :gsectorsize
	# filesystem superblock
	attr_reader :fs

	# Cache instances since REXML is dog slow
	@@CACHED = {}

	# @param geomdev short gom device name
	# @return cached FSInfo
	def FSInfo.get(geomdev)
		@@CACHED[geomdev] ||= FSInfo.new(geomdev)
	end

	# @param geom device name
	def initialize(geomdev)
		@dev = geomdev
		@fs = ffsinfo(dev).sblock
		@mountpoint = fs.fsmnt # XXX is it current or just previous mountpoint ?
		@gprovider = $gmesh.provider(dev)
		@gsectorsize = 512 # XXX why @gprovider.sectorsize is 4096 ?
	end

	# from ufs/ffs/fs.h:

	def fsbtodb(b)
		b << fs.fsbtodb
	end
	def dbtofsb(b)
		b >> fs.fsbtodb
	end
	def fragnum(fsb)
		# fsb % fs.frag
		fsb & (fs.frag - 1)
	end
	def blknum(fsb)
		# rounddown(fsb, fs.frag)
		fsb &~ (fs.frag - 1)
	end

	def dputs(*args)
		puts(*args) if $DEBUG
	end

	# @param offset in bytes
	# @return disk block
	def offset2diskblock(offset)
		dputs "off #{offset} blk +#{offset % fs.bsize}"
		# logical block number
		lbn = offset / gsectorsize
		dputs "lbn #{lbn}"
		# disk block this lbn lies in
		db = blknum(lbn)
		dputs "db  #{db}"
		# convert to fs block
		fsb = dbtofsb(db)
		dputs "fsb #{fsb}"
		# add fragment number of this lbn
		fsb += fragnum(lbn)
		dputs "fragnum #{fragnum(lbn)}"
		# convert back to disk block
		db = fsbtodb(fsb)
		dputs "db  #{db}"
		dputs
		db
	end

	# @param disk_block number (up to 32)
	# @return map of blocks to inodes
	# TODO move to separate class FSDB and keep process working between calls
	# XXX reading before exit blocks no matter what, even with PTY.spawn, why? 
	def findblk(*disk_blocks)
		IO.popen "fsdb -r /dev/#{dev}",'w+' do |fsdb|
			# TODO fsdb.puts "help" and grab commands
			fsdb.puts "findblk #{disk_blocks.join ' '}"
			fsdb.puts "exit"
			results = {}
			fsdb.each_line do |line|
				case line
				when /(\d+): data block of inode (\d+)/
					results[Integer $1] = Integer $2
				end
			end
			results
		end
	end

	# @param list of inodes
	# @return list of paths
	def findpaths(inodes)
		return [] if inodes.empty?
		`find -x #{fs.fsmnt} \\( -inum #{inodes.join ' -or -inum '} \\) -print0`.split "\0"
	end
end

GeomError = Struct.new(:date,:geom,:op,:off,:len)

FSDB_FINDBLK_MAXARGC = 32

# GEOM_FOO: g_foo_read_done() failed ad0s1d[READ(offset=123456, length=512)]
RE_GEOMERR = /(GEOM_\S+): (\S+) failed (\S+)\[(\S+)\(offset=(\d+), length=(\d+)\)\]/
	//x if false # XXX fix vim indent

errors = []
while gets do
	for gclass,fun,geom,op,off,len in scan(RE_GEOMERR) do
		begin # try to parse date like in syslog
			date = DateTime.strptime($_, '%b %e %T')
		rescue ArgumentError
		end
		errors << GeomError.new(date, geom, op, Integer(off), Integer(len))
	end
end

for geom,gerrors in errors.group_by {|e|e.geom} do
	puts "GEOM #{geom}"
	fsinfo = FSInfo.get(geom)

	# findblk handles up to 32 blocks per run

	# Each offset+length is unique location
	# Maybe group by offset and select largest length ?
	for loc,lerrors in gerrors.group_by {|e|[e.off,e.len]} do
		off,len = loc
		puts "ERROR OFFSET #{off} SIZE #{len} COUNT #{lerrors.length}"
	end

	inodes = {}
	errbyloc = gerrors.group_by {|e|e.off}
	errbyloc.keys.sort.each_slice(FSDB_FINDBLK_MAXARGC) do |offsets|
		dblocks = offsets.map{|o| fsinfo.offset2diskblock(o)}
		puts "FINDINODE BLOCKS #{dblocks.join ' '}"
		inodes.merge! fsinfo.findblk(dblocks)
	end
	inums = inodes.values.uniq.sort
	puts "FINDPATH \"#{fsinfo.mountpoint}\" INODES #{inums.join ' '}"
	blocks = inodes.group_by {|blk,ino|ino}
	paths = fsinfo.findpaths inums
	for path in paths.sort do
		inode = File.stat(path).ino
		blks = blocks[inode].map{|blk,ino|blk}
		printf "PATH \"%s\" INODE %d BLOCKS %s\n", path, inode, blks.join(' ')
	end
end

