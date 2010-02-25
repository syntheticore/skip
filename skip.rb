#!/usr/bin/env ruby
#
#  Created by Björn Breitgoff on 23.2.2010.


module Skip

  # override the given method with a JIT optimized one
  def self.optimize klass, meth
    alias_name = meth.to_s + "_original"
    lambda = jit_lambda klass, alias_name
    klass.send :alias_method, alias_name, meth
    klass.send :define_method, meth, lambda
  end
  
  # takes a block and returns a JIT optimized version of it
  def self.optimized &b
    # inject block into wrapper class
    wrapper = Class.new
    wrapper.send :define_method, :code, b
    num_args_required = [b.arity, 0].max
    jit_lambda wrapper, :code
  end
  
  # takes a class and a method name and returns a JIT optimized lambda 
  # The code may only use Numerical classes and arrays
  def self.jit_lambda klass, meth
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
          block = sexp#.find{|t| t.is_a? Array }
          #puts sexp.inspect
          # run original code to determine return type
          retval = klass.new.send meth, *args
          # build a signature to match the types of the first run
          signature = { args.map{|a| $jit_types[a.class]} => $jit_types[retval.class] }
          # compile syntax tree to machine code
          jit = JIT::Function.build(signature) do |f|
            # compile parse tree recursively
            r = Skip::compile block, f, {}, args.size
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
    when :return
      puts token.inspect
      expr = token.first
      f.return recurse[:expr]
    when :bmethod  # lambda definition
      signature, code = token
      recurse[:signature] if signature
      recurse[:code]
    when :args
      for varname in token
        jit_vars[varname] ||= f.value($jit_types[Fixnum], 0)
      end
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
      f.value( $jit_types[value.class], value )
    when :dvar, :lvar  # local variable
      name = token.first
      # we need to create the var if it doesn't exist, 
      # because it can be referenced before it is assigned to
      jit_vars[name] ||= f.value($jit_types[Fixnum], 0)
      jit_vars[name]
    when :dasgn, :dasgn_curr  # assignment to local variable
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
      token.map{|expr| recurse[:expr] }
    when :call
      obj, method, args = token
      obj = recurse[:obj]
      args = recurse[:args]
      case method.to_s
      when *%w{ + - * / < > % == }
        obj.send method, args.first
      else
        puts "WARNING: Calling #{method} is not supported"
      end
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
      f.while{ lhs.send op, rhs.first }.do{
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
        array_type = JIT::Array.new(JIT::Type::INT, receiver.size)
        array_instance = array_type.create(f)
        receiver.each_with_index{|v,i| array_instance[i] = v }
        i = f.value(:INT, 0)
        f.while{ i < receiver.size }.do{
          param.store array_instance[0] + i
          recurse[:code]
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
  
  class A
    def blub a
      return 4 if a == 0
      5
      #a + blub(a-1)
    end
  end

  puts "-" * 60
  
  r = A.new.blub 3
  Skip::optimize A, :blub
  puts A.new.blub 0
  puts r

#  n = 200
#  Benchmark.bm do |x|
#    GC.start
#    x.report{ n.times{ A.new.blub } }
#    
#    Skip::optimize A, :blub
#    GC.start
#    x.report{ n.times{ A.new.blub } }
#  end
end



