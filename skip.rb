#!/usr/bin/env ruby
#
#  Created by Björn Breitgoff on 23.2.2010.


module Skip
  # optimized can either be called with a block, to return  a jitted version of it, 
  # or with a class and a methodname, to override the given method with an optimized one
  def self.optimized klass=nil, meth=nil, &b
    if klass and meth
      lambda = optimize klass, meth
    elsif block_given?
      # inject block into wrapper class
      wrapper = Class.new
      wrapper.send :define_method, :code, b
      num_args_required = [b.arity, 0].max
      optimize wrapper, :code
    else
      raise "Optimized takes either a class and a methodname or a block"
    end
  end
  
  # optimize takes a class and a method name and returns a jit optimized lambda 
  # The code may only use Numerical classes and arrays
  def self.optimize klass, meth
    begin
      require 'rubygems'
      require 'jit'
      require 'parse_tree'
      $jit_types = {
        Fixnum => :INT,
        Float => :DOUBLE }
      # find a name for preserving runtime information about the code
      Thread.current[:jit_result_info] ||= {}
      name = Object.new
      lambda do |*args|
        # on first run...
        if !Thread.current[:jit_result_info][name]
          # build parse tree from given method
          sexp = ParseTree.translate klass, meth
          block = sexp.find{|t| t.is_a? Array }
          puts sexp.inspect
          # run original code to determine return type
          retval = klass.new.send meth, *args
          # build a signature to match the types of the first run
          signature = {args.map{|a| $jit_types[a.class] } => $jit_types[retval.class]}
          # compile syntax tree to machine code
          jit = JIT::Function.build(signature) do |f|
            # compile parse tree recursively
            r = compile block, f, {}, args.size
            # return the last result produced
            f.return r
          end
          #puts jit.dump
          Thread.current[:jit_result_info][name] = [retval, jit]
          retval
        else
          # run the compiled code once it exists
          retval, jit  = Thread.current[:jit_result_info][name]
          r = jit.apply *args
          raise "Compilation failed for this piece of code" if r != retval and not $debug
          r
        end
      end
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
    name = token.shift
    puts name
    case name
    when :bmethod  # lambda definition
      signature, code = token
      recurse['signature']
      recurse['code']
      #compile signature, f, jit_vars, num_args if signature
      #compile code, f, jit_vars, num_args
    when :masgn  # init multiple block parameters
      puts token.inspect
      params, unknown, unknown = token
      params = compile params, f, jit_vars, num_args
      args = (0...num_args).map{|i| f.param i }
      params.zip(args) do |p,a|
        jit_vars[p] = a
      end
      nil
    when :lit  # literal
      value = token.first
      f.value( $jit_types[value.class], value )
    when :dvar  # local variable
      name = token.first
      # we need to create the var if it doesn't exist, 
      # because it can be referenced before it is assigned to
      jit_vars[name] ||= f.value($jit_types[Fixnum], 0)
      jit_vars[name]
    when :dasgn, :dasgn_curr  # assignment to local variable
      varname, expr = token
      if expr
        expr = compile expr, f, jit_vars, num_args
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
      token.map{|expr| compile expr, f, jit_vars, num_args }
    when :block
      for expr in token
        r = compile expr, f, jit_vars, num_args
      end
      r
    when :call
      obj, method, args = token
      obj = compile obj, f, jit_vars, num_args
      args = compile args, f, jit_vars, num_args
      case method.to_s
      when *%w{ + - * / < > % == }
        obj.send method, args.first
      else
        puts "WARNING: Calling #{method} is not supported"
      end
    when :if
      cond, code, retval = token
      cond = compile cond, f, jit_vars, num_args
      f.if( cond ) {
        compile code, f, jit_vars, num_args
      }.end
    when :while
      cond, code, retval = token
      dummy, lhs, op, rhs = cond
      lhs = compile lhs, f, jit_vars, num_args
      rhs = compile rhs, f, jit_vars, num_args
      f.while{ lhs.send op, rhs.first }.do{
        compile code, f, jit_vars, num_args
      }.end
      retval
    when :iter
      meth, param, code = token
      dummy, receiver, meth = meth
      if param
        param = compile param, f, jit_vars, num_args 
        param = jit_vars[param] = f.value(:INT,0)
      end
      receiver = compile receiver, f, jit_vars, num_args
      case meth
      when :times 
        param ||= f.value(:INT,0)
        f.while{ param < receiver }.do{
          compile code, f, jit_vars, num_args
          param.store param + 1
        }.end
      when :each
        array_type = JIT::Array.new(JIT::Type::INT, receiver.size)
        array_instance = array_type.create(f)
        receiver.each_with_index{|v,i| array_instance[i] = v }
        i = f.value(:INT, 0)
        f.while{ i < receiver.size }.do{
          param.store array_instance[0] + i
          compile code, f, jit_vars, num_args
          i.store i + 1
        }.end
      else
        puts "WARNING: Can't compile #{meth} iterator"
      end
    else
      puts "WARNING: Can't compile #{name} instruction"
    end
  end
end


if __FILE__ == $0
  require 'benchmark'
  $debug = true
  
  sum = lambda do |n|
    a = []
    n.times do |e|
      a << e
    end
    a[n-1]
    7
  end

  sumo = Skip::optimized &sum

  puts "-" * 60
  puts sumo[20]
  puts sumo[20]

  n = 2
  Benchmark.bm do |x|
    x.report{ n.times{ sum[99999] } }
    GC.start
    x.report{ n.times{ sumo[99999] } }
  end
end



