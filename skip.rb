#!/usr/bin/env ruby
#
#  Created by Björn Breitgoff on 23.2.2010.
#

require 'rubygems'
require 'benchmark'


# optimized takes a block and returns a jit optimized version of it
# The code may only use Numerical classes and arrays

def optimized &b
  begin
    require 'jit'
    require 'parse_tree'
    $jit_types = {
      Fixnum => :INT,
      Float => :DOUBLE }
    # find a name for preserving runtime information about the code
    Thread.current[:jit_result_info] ||= {}
    name = Object.new
    lambda do |*args|
      # check that the arguments given to the lambda
      # match those of the original definition
      num_required_args = [b.arity, 0].max
      num_args_given = args.size
      raise ArgumentError, "Wrong number of arguments (#{num_args_given} for #{num_required_args})" if num_args_given != num_required_args
      # on first run...
      if !Thread.current[:jit_result_info][name]
        # inject block into wrapper class
        wrapper = Class.new
        wrapper.send :define_method, :code, b
        # build parse tree from that
        sexp = ParseTree.translate wrapper, :code
        block = sexp.drop_level
        # run original code to determine return type
        retval = yield *args
        # build a signature to match the types of the first run
        signature = {args.map{|a| $jit_types[a.class] } => $jit_types[retval.class]}
        # compile syntax tree to machine code
        jit = JIT::Function.build(signature) do |f|
          # compile parse tree recursively
          r = compile block, f, {}, num_args_given
          # return the last result produced
          f.return r
        end
        puts jit.dump
        Thread.current[:jit_result_info][name] = [retval, jit]
        retval
      else
        # run the compiled code once it exists
        retval, jit  = Thread.current[:jit_result_info][name]
        r = jit.apply *args
        #raise "Compilation failed for this piece of code" if r != retval
        r
      end
    end
  rescue LoadError
    # return unmodified block if dependencies are not met
    puts "WARNING: ruby-libjit and ParseTree gems are required for JIT compilation"
    b
  end
end

def compile token, f, jit_vars, num_args
  puts token.inspect
  name = token.shift
  puts name
  case name
  when :bmethod  # lambda definition
    signature, code = token
    compile signature, f, jit_vars, num_args if signature
    compile code, f, jit_vars, num_args
  when :masgn  # init block parameters
    params, unknown, unknown = token
    params = compile params, f, jit_vars, num_args
    args = (0...num_args).map{|i| f.param i }
    params.zip(args) do |p,a|
      jit_vars[p] = a
    end
    nil
  when :lit  # literal
    value = token.first
    lit = f.value( $jit_types[value.class], value )
    lit
  when :dvar  # local variable
    name = token.first
    # we need to create the var if it doesn't exist, 
    # because it can be referenced before it is assigned to
    jit_vars[name] ||= f.value($jit_types[Fixnum], 0)
  when :dasgn_curr  # assignment to local variable
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
      # just return the name so that :masgn can map it to the jit params
      varname
    end
  when :array
    token.map{|expr| puts expr.inspect; compile expr, f, jit_vars, num_args }
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
  else
    puts "WARNING: Can't compile #{name} instruction"
  end
end

class Array
  def drop_level
    for token in self
      return token if token.is_a? Array
    end
    nil
  end
end


sum = lambda do |i,a|
  r = 0
  while i < a
    i += 2
    a += 1
    r += 1 if a % 2 == 0
  end
  r
end

#fib = lambda do |n,m|
#  a = 2
#  b = 8
#  c = 1
#  i = 0
#  while i < n
#    c = a + b / 2
#    a = b
#    b = c
#    i += 1
#  end
#  c
#end


#fibo = optimized &fib
sumo = optimized &sum

#puts  fib[42,1]
#puts fibo[42,1]
#puts  fib[42,1]
#puts fibo[42,1]

puts sumo[2,9999]
puts  sum[2,9999]
puts "-" * 60
puts sumo[50,5000]
puts  sum[50,5000]


n = 100
Benchmark.bm do |x|
  x.report{ n.times{ sum[2,99999] } }
  GC.start
  x.report{ n.times{ sumo[2,99999] } }
end




