require 'net/ssh/buffer'

module Net; module SFTP; module Protocol; module V01

  # A class representing the attributes of a file or directory on the server.
  # It may be used to specify new attributes, or to query existing attributes.
  class Attributes

    F_SIZE        = 0x00000001
    F_UIDGID      = 0x00000002
    F_PERMISSIONS = 0x00000004
    F_ACMODTIME   = 0x00000008
    F_EXTENDED    = 0x80000000
    
    attr_accessor :size
    attr_accessor :uid
    attr_accessor :gid
    attr_accessor :permissions
    attr_accessor :atime
    attr_accessor :mtime
    attr_accessor :extended

    # Create a new Attributes object, initialized from the given buffer.
    def self.from_buffer(buffer)
      flags = buffer.read_long

      size  = buffer.read_int64 if flags & F_SIZE != 0
      uid   = buffer.read_long  if flags & F_UIDGID != 0
      gid   = buffer.read_long  if flags & F_UIDGID != 0
      perms = buffer.read_long  if flags & F_PERMISSIONS != 0
      atime = buffer.read_long  if flags & F_ACMODTIME != 0
      mtime = buffer.read_long  if flags & F_ACMODTIME != 0

      if flags & F_EXTENDED != 0
        extended = Hash.new
        buffer.read_long.times do
          extended[buffer.read_string] = buffer.read_string
        end
      end

      new(:size => size, :uid => uid, :gid => gid, :permissions => perms,
        :atime => atime, :mtime => mtime, :extended => extended)
    end

    # Create a new attributes object, initialized from the given hash. The
    # :owner and :group attributes are treated specially; they are not actually
    # supported by this version of the protocol, but are instead converted
    # by this method to their corresponding id numbers, and assigned
    # (respectively) to :uid and :gid.
    def self.from_hash(hash)
      if hash[:owner]
        require 'etc'
        hash[:uid] = Etc.getpwnam( hash[:owner] ).uid
      end

      if hash[:group]
        require 'etc'
        hash[:gid] = Etc.getgrnam( hash[:group] ).gid
      end

      new(hash)
    end

    # Create a new Attributes with the given attributes.
    def initialize(options={})
      @size        = options[:size]
      @uid         = options[:uid]
      @gid         = options[:gid]
      @permissions = options[:permissions]
      @atime       = options[:atime]
      @mtime       = options[:mtime]
      @extended    = options[:extended]
    end

    # Convert the object to a string suitable for passing in an SFTP
    # packet.
    def to_s
      flags = 0

      flags |= F_SIZE if @size
      flags |= F_UIDGID if @uid && @gid
      flags |= F_PERMISSIONS if @permissions
      flags |= F_ACMODTIME if @atime && @mtime
      flags |= F_EXTENDED if @extended

      buffer = Net::SSH::Buffer.from(:long, flags)
      buffer.write_int64 @size if @size
      buffer.write_long @uid, @gid if @uid && @gid
      buffer.write_long @permissions if @permissions
      buffer.write_long @atime, @mtime if @atime && @mtime

      if @extended
        buffer.write_long @extended.size
        @extended.each { |k,v| buffer.write_string k, v }
      end

      buffer.to_s
    end

  end

end ; end ; end ; end
