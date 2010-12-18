require 'mysql'

# allow access to the real Mysql connection
class ActiveRecord::ConnectionAdapters::MysqlAdapter
  attr_reader :connection
end

# MysqlSession is a down to the bare metal session store
# implementation to be used with +SmartSessionStore+. It is much faster
# than the default ActiveRecord implementation.
#
# The implementation assumes that the table column names are 'id',
# 'data', 'created_at' and 'updated_at'. If you want use other names,
# you will need to change the SQL statments in the code.

class MysqlSession

  attr_accessor :id, :session_id, :data, :updated_at, :lock_version

  def initialize(session_id, data)
    @session_id = session_id
    @data = data
    @id = nil
    @updated_at = Time.now
    @lock_version = 0
  end

  class << self

    # retrieve the session table connection and get the 'raw' Mysql connection from it
    def session_connection
      SqlSession.connection.connection
    end

    def query(sql)
      connection = session_connection
      begin
        connection.query sql
      rescue Exception => e
        message = "#{e.class.name}: #{e.message}: #{sql}"
        raise ActiveRecord::StatementInvalid, message
      end
    end
    # try to find a session with a given +session_id+. returns nil if
    # no such session exists. note that we don't retrieve
    # +created_at+ and +updated_at+ as they are not accessed anywhyere
    # outside this class
    def find_session(session_id, lock = false)
      find("`session_id`='#{Mysql.quote session_id}' LIMIT 1" + (lock ? ' FOR UPDATE' : ''))
    end
    
    def find_by_primary_id(primary_key_id, lock = false)
      if primary_key_id
        find("`id`='#{primary_key_id}'" + (lock ? ' FOR UPDATE' : ''))
      else
        nil
      end
    end
    
    def find(conditions)
      connection = session_connection
      connection.query_with_result = true
      result = query("SELECT session_id, data, id, updated_at #{  SqlSession.locking_enabled? ? ',lock_version ' : ''} FROM sessions WHERE " + conditions)
       my_session = nil
      # each is used below, as other methods barf on my 64bit linux machine
      # I suspect this to be a bug in mysql-ruby
      result.each do |row|
        my_session = new(row[0], row[1])
        my_session.id = row[2]
        my_session.updated_at = Time.parse(row[3])
        my_session.lock_version = row[4].to_i
      end
      result.free
      my_session
    end  
    # create a new session with given +session_id+ and +data+
    # and save it immediately to the database
    def create_session(session_id, data)
      session_id = Mysql::quote(session_id)
      new_session = new(session_id, data)
      new_session
    end

    # delete all sessions meeting a given +condition+. it is the
    # caller's responsibility to pass a valid sql condition
    def delete_all(condition=nil)
      if condition
        query("DELETE FROM sessions WHERE #{condition}")
      else
        query("DELETE FROM sessions")
      end
    end

  end # class methods

  # update session with given +data+.
  # unlike the default implementation using ActiveRecord, updating of
  # column `updated_at` will be done by the datbase itself
  def update_session(data)
    connection = self.class.session_connection
    if @id
      # if @id is not nil, this is a session already stored in the database
      # update the relevant field using @id as key
      if SqlSession.locking_enabled?
        self.class.query("UPDATE sessions SET `updated_at`=NOW(), `data`='#{Mysql::quote(data)}', lock_version=lock_version+1 WHERE id=#{@id}")
        @lock_version += 1 #if we are here then we hold a lock on the table - we know our version is up to date
      else
        self.class.query("UPDATE sessions SET `updated_at`=NOW(), `data`='#{Mysql::quote(data)}' WHERE id=#{@id}")
      end
    else
      # if @id is nil, we need to create a new session in the database
      # and set @id to the primary key of the inserted record
      self.class.query("INSERT INTO sessions (`updated_at`, `session_id`, `data`) VALUES (NOW(), '#{@session_id}', '#{Mysql::quote(data)}')")
      @id = connection.insert_id
      @lock_version = 0
    end
  end

  def update_session_optimistically(data)
    raise 'cannot update unsaved record optimistically' unless @id
    connection = self.class.session_connection
    self.class.query("UPDATE sessions SET `updated_at`=NOW(), `data`='#{Mysql::quote(data)}', `lock_version`=`lock_version`+1 WHERE id=#{@id} AND lock_version=#{@lock_version}")
    if connection.affected_rows == 1
      @lock_version += 1
      true
    else
      false
    end
  end

  def touch_session
    self.class.session_connection.query("UPDATE sessions SET updated_at = NOW() WHERE id = #{@id}") if @id
  end

  # destroy the current session
  def destroy
    self.class.delete_all("session_id='#{session_id}'")
  end

end

__END__

# This software is released under the MIT license
#
# Copyright (c) 2007 Frederick Cheung
# Copyright (c) 2005,2006 Stefan Kaes

# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:

# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
