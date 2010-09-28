#!/usr/bin/env ruby
# vim: set ai ts=2 sw=2:

require 'date'
require 'ostruct'
require 'rexml/document'

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
		include REXML
		def initialize(node)
			@node = node
		end
		def method_missing(m, *args, &block)
			# XXX child = XPath.first(@node, '$m', nil, 'm' => m)
			child = XPath.first(@node, m.to_s)
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
	# sector size of geom provider
	attr_reader :gsectorsize
	# fsbtodb factor
	attr_reader :fsbtodb

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
		@sblock = ffsinfo(dev).sblock
		@fsbtodb = @sblock.fsbtodb
		@gprovider = $gmesh.provider(dev)
		@gsectorsize = @gprovider.sectorsize
	end

	# @param offset geom offset in bytes
	# @return disk? block XXX verify
	def goffset2diskblock(offset)
		# TODO
	end

	# disk_block = fs_block * (2** fsbtodb)

	def fs2disk_block(fs_block)
		fs_block << fsbtodb
	end
	def disk2fs_block(disk_block)
		disk_block >> fsbtodb
	end

	# @param disk_block number (TODO up to 32)
	# @return inode number or nil # TODO block=>[inode]
	def findblk(*disk_block)
		# TODO
		puts "FINDBLK #{disk_block.join ' '}"
	end
end

GeomError = Struct.new(:date,:geom,:op,:off,:len)

FSDB_FINDBLK_MAXARGC = 32

# GEOM_FOO: g_foo_read_done() failed ad0s1d[READ(offset=123456, length=512)]
RE_GEOMERR = /(GEOM_\S+): (\S+) failed (\S+)\[(\S+)\(offset=(\d+), length=(\d+)\)\]/
	//x # XXX fix vim indent

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
		puts "  OFFSET #{off} SIZE #{len} COUNT #{lerrors.length}"
	end

	errbyloc = gerrors.group_by {|e|e.off}
	errbyloc.keys.sort.each_slice(FSDB_FINDBLK_MAXARGC) do |offsets|
		fsblocks = offsets
		dblocks = fsblocks
		puts "  FINDBLK #{dblocks.join ' '}"
		fsinfo.findblk(dblocks)
	end
end

