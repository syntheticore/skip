#!/usr/bin/env ruby
#
#  Created by Björn Breitgoff on 23.2.2010.
#

require 'rubygems'
require 'parse_tree'
require 'benchmark'


# optimized takes a block and returns a jit optimized version of it
# The code may only use Numerical classes and arrays

def optimized &b
  begin
    require 'jit'
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
        Wrapper.send :define_method, :code, b
        # build parse tree from that
        sexp = ParseTree.translate Wrapper, :code
        block = sexp.drop_level
        # run original code to determine return type
        retval = yield *args
        # build a signature to match the types of the first run
        signature = {args.map{|a| $jit_types[a.class] } => $jit_types[retval.class]}
        # compile syntax tree to machine code
        jit = JIT::Function.build(signature) do |f|
          # map ruby args to their jit versions
          jit_vars = {}
          num_args_given.times do |i|
            jit_vars[args[i]] = f.param(i)
          end
          # compile parse tree recursively
          r = compile block, f, jit_vars
          # return the last result produced
          f.return r
        end
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
    b # return the unmodified block if libjit is not available
  end
end

def compile token, f, jit_vars
  name = token.shift
  puts name
  case name
  when :bmethod  # lambda definition
    signature, code = token
    compile signature, f, jit_vars if signature
    puts code.inspect
    puts "-" * 60
    compile code, f, jit_vars
  when :lit  # literal
    value = token.first
    lit = f.value( $jit_types[value.class], value )
    lit
  when :dvar  # local variable
    name = token.first
    # we need to create the var if it doesn't exist, 
    # because it can be referenced before it is asigned to
    jit_vars[name] ||= f.value($jit_types[Fixnum], 0)
  when :dasgn_curr  # assignment to local variable
    varname, expr = token
    expr = compile expr, f, jit_vars
    if jit_vars[varname]
      jit_vars[varname].store expr
    else
      jit_vars[varname] = expr
    end
  when :array
    token.map{|expr| compile expr, f, jit_vars }
  when :block
    r = nil
    for expr in token
      r = compile expr, f, jit_vars
    end
    r
  when :call
    obj, method, args = token
    obj = compile obj, f, jit_vars
    args = compile args, f, jit_vars
    case method
    when  :+, :-, :*, :/, :<
      r = f.value( $jit_types[Fixnum], 0)
      obj.send method, args.first
    end
  when :while
    cond, code, unknown = token
    puts cond.inspect, code.inspect, unknown.inspect
    j = f.value(:INT, 0)
    cond = compile cond, f, jit_vars
    f.while{ cond }.do{
      compile code, f, jit_vars
      j.store j + 1
    }.end
  else
    puts "WARNING: can't compile #{name}"
  end
end

class Wrapper
end

class Array
  def drop_level
    for token in self
      return token if token.is_a? Array
    end
    nil
  end
end


sum = lambda do
  i = 0
  while i < 5
    i += 1
  end
  i
end

sumo = optimized &sum

puts sumo[]
puts "-" * 60
puts sumo[]


n = 900
Benchmark.bm do |x|
  x.report{ n.times{ sum[] } }
  GC.start
  x.report{ n.times{ sumo[] } }
end





#def optimized &b
#  begin
#    require 'jit'
#    $jit_types = {
#      Fixnum => :INT,
#      Float => :DOUBLE }
#    # find a name for preserving runtime information about the code
#    Thread.current[:jit_result_info] ||= {}
#    name = Object.new
#    lambda do |*args|
#      # check that the arguments given to the lambda
#      # match those of the original definition
#      num_required_args = b.arity
#      num_args_given = args.size
#      raise ArgumentError, "Wrong number of arguments (#{num_args_given} for #{num_required_args})" if num_args_given != num_required_args
#      # on first run...
#      if !Thread.current[:jit_result_info][name]
#        # call the regular code and trace execution
#        log = []
#        Thread.current[:current_jit_log] = log
#        wrapped_args = args.map{|a| ActionLogger.new a }
#        retval = yield *wrapped_args
#        # build a signature to match the types of the first run
#        signature = {args.map{|a| $jit_types[a.class] } => $jit_types[retval.value.class]}
#        # compile log to machine code
#        jit = JIT::Function.build(signature) do |f|
#          # map ruby args to their jit versions
#          jit_vars = {}
#          num_args_given.times do |i|
#            jit_vars[wrapped_args[i]] = f.param(i)
#          end
#          # convert log operations to jit instructions
#          idx = 0
#          while idx = compile(idx, log, jit_vars, f); end
#          # return the last result produced
#          f.return jit_vars[retval]
#        end
#        Thread.current[:jit_result_info][name] = [retval, jit]
#        retval.value
#      else
#        # run the compiled code once it exists
#        retval, jit  = Thread.current[:jit_result_info][name]
#        r = jit.apply *args
#        #raise "Compilation failed for this piece of code" if r != retval
#        r
#      end
#    end
#  rescue LoadError
#    b # return the unmodified block if libjit is not available
#  end
#end


## Compile a stream of instructions, beginning at the given index
## Returns the next index after the instructions already compiled
## or nil, when the compilation is complete

#def compile instr_idx, log, jit_vars, f
#  return unless log[instr_idx]
#  lhs, op, rhs, result = log[instr_idx]
#  if op != :times and rhs.value
#    if jit_vars[rhs]
#      # right hand side was an argument or resulted from an operation
#      rhs = jit_vars[rhs]
#    else
#      # right hand side was a literal
#      # As these are constant, we take their value from the original run
#      rhs = f.value( $jit_types[rhs.value.class], rhs.value )
#    end
#  end
#  # compile operation
#  case op
#  when :+, :-, :*, :/
#    # create a var for holding result that matches type of original result
#    r = f.value( $jit_types[result.value.class], 0)
#    jit_vars[result] = r
#    r.store jit_vars[lhs].send op, rhs
#    return instr_idx + 1
#  when :times
#    actions_executed = rhs
#    actions_per_run = actions_executed / lhs.value
#    j = f.value(:INT, 0)
#    f.while{ j < jit_vars[lhs] }.do{
#      # recursively compile the following operations inside the loop
#      actions_per_run.times{|k| compile instr_idx+1+k, log, jit_vars, f }
#      j.store j + 1
#    }.end
#    return instr_idx + actions_executed
#  when :store
#    jit_vars[lhs].store rhs
#    return instr_idx + 1
#  end
#end


## ActionLogger works like a proxy for an object that
## creates a log of all method calls

#class ActionLogger
#  has :value
#  
#  def method_missing meth, *args, &b
#    arg = args.first
#    arg = ActionLogger.new arg unless arg.is_a? ActionLogger
#    v = if block_given?
#      @value.send meth, *[arg.value].compact, &b
#    else
#      @value.send meth, *[arg.value].compact
#    end
#    v = ActionLogger.new v
#    Thread.current[:current_jit_log] << [self, meth, arg, v]
#    v
#  end
#  
#  def store o
#    @value = o.value
#    Thread.current[:current_jit_log] << [self, :store, o, nil]
#  end
#  
#  def times &b
#    iterator :times, &b
#  end
#  
#  def each &b
#    iterator :each, &b
#  end
#  
#  def iterator name
#    log = Thread.current[:current_jit_log]
#    entry = [self, name]
#    log << entry
#    s = log.size
#    @value.send(name){|e| yield e }
#    n = log.size - s
#    entry << n << nil
#  end
#end


