#!/usr/bin/env ruby
#
#  Created by Björn Breitgoff on 23.2.2010.


module Skip

  JIT_TYPES = {
    Fixnum => :INT,
    Float => :DOUBLE }
    
  # takes a block and returns a JIT optimized version of it
  def self.optimized &b
    # inject block into wrapper class
    wrapper = Class.new
    wrapper.send :define_method, :code, b
    optimize wrapper, :code
    w = wrapper.new
    lambda{|*args| w.code *args }
  end
  
  # override the given method with a JIT optimized one
  # The code may only use Numerical classes and arrays
  def self.optimize klass, meth, *setup_args
    begin
      require 'rubygems'
      require 'jit'
      require 'parse_tree'
      # find a name for preserving runtime information about the code
      Thread.current[:jit_result_info] ||= {}
      name = Object.new
      l = lambda do |*args|
        if Thread.current[:testrun]
          klass.new.send meth.to_s + "_original", *args
        elsif !Thread.current[:jit_result_info][name]
          # on first run...
          # build parse tree from given method
          sexp = ParseTree.translate klass, meth.to_s + "_original"
          #puts sexp.inspect
          # run original code to determine return type
          Thread.current[:testrun] = true
          retval = klass.new.send meth, *args
          Thread.current[:testrun] = false
          # build a signature to match the types of the first run
          signature = { args.map{|a| JIT_TYPES[a.class]} => JIT_TYPES[retval.class] }
          # compile syntax tree to machine code
          jit = JIT::Function.build(signature) do |f|
            # compile parse tree recursively
            r = Skip::compile sexp, f, {}, args.size
            # return the last result produced
            f.return r
          end
          #puts jit.dump
          # save the compiled method for future use
          Thread.current[:jit_result_info][name] = [retval, jit]
          # check if it returns the correct result
          raise "Compilation failed for this piece of code" if retval != jit.apply(*args) and not $debug
          retval
        else
          # run the compiled code once it exists
          retval, jit  = Thread.current[:jit_result_info][name]
          jit.apply *args
        end
      end
      klass.send :alias_method, meth.to_s + "_original", meth
      klass.send :define_method, meth, l
      klass.new.send meth, *setup_args unless setup_args.empty?
    rescue LoadError
      # return unmodified block if dependencies are not met
      puts "WARNING: ruby-libjit and ParseTree gems are required for JIT compilation"
      b
    end
  end

  # compile takes an AST token and compiles 
  # it recursively into the given function
  def self.compile token, f, jit_vars, num_args
    recurse = lambda{|var| eval "compile #{var}, f, jit_vars, num_args" }
    #puts token.inspect
    name = token.shift
    puts name
    case name
    when :defn
      name, body = token
      recurse[:body]
    when :fbody, :scope
      scope = token.first
      recurse[:scope]
    when :block
      for expr in token
        r = recurse[:expr]
      end
      r
    when :args
      params = token
      args = (0...num_args).map{|i| f.param i }
      params.zip(args) do |p,a|
        jit_vars[p] = a
      end
    when :return
      expr = token.first
      f.insn_return recurse[:expr]
    when :bmethod  # lambda definition
      signature, code = token
      recurse[:signature] if signature
      recurse[:code]
    when :masgn  # init multiple block parameters
      params, unknown, unknown = token
      params = recurse[:params]
      args = (0...num_args).map{|i| f.param i }
      params.zip(args) do |p,a|
        jit_vars[p] = a
      end
      nil
    when :lit  # literal
      value = token.first
      jit_value = f.value( JIT_TYPES[value.class], value )
      # save the ruby value for static array accesses
      $literals ||= {}
      $literals[jit_value] = value
      jit_value
    when :dvar, :lvar  # local variable
      name = token.first
      # we need to create the var if it doesn't exist, 
      # because it can be referenced before it is assigned to
      jit_vars[name] ||= f.value(JIT_TYPES[Fixnum], 0)
      jit_vars[name]
    when :dasgn, :lasgn, :dasgn_curr  # assignment to local variable
      varname, expr = token
      if expr
        expr = recurse[:expr]
        jv = jit_vars[varname]
        if jv
          jv.store expr
        else
          jit_vars[varname] = expr
        end
        jv
      else
        # var is a block parameter
        # init it here in case it is the only block param
        jit_vars[varname] = f.param 0
        # return the name so that :masgn can map it to the jit params in case of multiple params
        varname
      end
    when :array
#      $array_sizes ||= {}
#      array_type = JIT::Array.new(JIT::Type::INT, token.size)
#      array_instance = array_type.create(f)
#      token.each_with_index{|expr,i| array_instance[i] = recurse[:expr] }
#      $array_sizes[array_instance] = token.size
#      array_instance
      token.map{|expr| recurse[:expr] }
    when :call
      obj, method, args = token
      obj = recurse[:obj]
      args = recurse[:args]
      case method.to_s
      when *%w{ + - * / < > % == <= >= }
        obj.send method, args[0]
      when "[]"
        #i = $literals[args[0]]
        obj[$literals[args[0]]]
      else
        puts "WARNING: Calling #{method} is not supported"
      end
    when :fcall
      function_name, args = token
      args = recurse[:args]
      f.insn_call("", f, 0, *args)
    when :if
      cond, code, retval = token
      cond = recurse[:cond]
      f.if( cond ) {
        recurse[:code]
      }.end
    when :while
      cond, code, retval = token
      dummy, lhs, op, rhs = cond
      lhs = recurse[:lhs]
      rhs = recurse[:rhs]
      f.while{ lhs.send op, rhs[0] }.do{
        recurse[:code]
      }.end
      retval
    when :iter
      meth, param, code = token
      dummy, receiver, meth = meth
      if param
        param = recurse[:param]
        param = jit_vars[param] = f.value(:INT,0)
      end
      receiver = recurse[:receiver]
      case meth
      when :times 
        param ||= f.value(:INT,0)
        f.while{ param < receiver }.do{
          recurse[:code]
          param.store param + 1
        }.end
      when :each
        #i = f.value(:INT, 0)
        #f.while{ i < receiver.size }.do{
        #f.while{ i < $array_sizes[receiver] }.do{
        for v in receiver
          param.store v
          cp = Marshal.load(Marshal.dump code)
          recurse[:cp]
        end
          #i.store i + 1
        #}.end
      when :map
#        array_type = JIT::Array.new(JIT::Type::INT, receiver.size)
#        original_array = array_type.create(f)
#        new_array = array_type.create(f)
#        receiver.each_with_index{|v,i| original_array[i] = v }
#        i = f.value(:INT, 0)
#        f.while{ i < receiver.size }.do{
#          param.store original_array[0] + i
#          e = recurse[:code]
#          (new_array[0] + i).store e
#          i.store i + 1
#        }.end
#        new_array
        new_array = Array.new(receiver.size){ f.value(:INT, 0) }
        receiver.each_with_index do|v,i|
          param.store v
          cp = Marshal.load(Marshal.dump code)
          e = recurse[:cp]
          new_array[i].store e
        end
        new_array
      else
        puts "WARNING: Can't compile #{meth} iterator"
      end
    else
      raise "WARNING: Can't compile #{name} instruction"
    end
  end
end



if __FILE__ == $0
  require 'benchmark'
  $debug = true
  
  class A
    def fib a
      return 0 if a == 0
      return 1 if a == 1
      fib(a-1) + fib(a-2)
    end
    
    def fub a
      s = 0
      n = [1,2,3].map do |e|
        e * 5
      end
      n.each do |e|
        s += e
      end
      s
    end
  end

  puts "-" * 60
  
  v = 19
  Skip::optimize A, :fub
  a = A.new
  puts a.fub v
  puts a.fub v
  puts a.fub v

#  n = 100
#  Benchmark.bm do |x|
#    GC.start
#    r = x.report{ n.times{ a.fib v } }
#    
#    Skip::optimize A, :fib, 1
#    
#    GC.start
#    jit = x.report{ n.times{ a.fib v } }
#    
#    puts "#{(r.real / jit.real).round} times faster"
#  end
end



