/**
	Author: Edmund Smith
	License: Apache-2.0
*/

module extensions;

import std.concurrency;
import std.container;
import std.typecons;
import std.typetuple;
import std.algorithm;
import std.conv;
import std.stdio;
import std.string;
import std.traits;
import std.variant;
import core.vararg;
import core.thread;

/**
	Lets the variable or function be accessed or evaluated in a lazy fashion without being a lazy parameter

	By hiding the variable inside a delegate, the variable is not called because it isn't touched, but is stored 
	inside the delegate which can be accessed normally. This calling this delegate then touches the lazy value.
	The lazyV struct get() method does this, and is aliased into lazyV itself, so accessing lazyV will return
	get() which returns the delegate, accessing and returning the lazy value only at the time that lazyV is 
	accessed.
*/
struct lazyV(V)
{
	V delegate() dg;
	
	this(lazy V v)
	{
		dg = delegate()
		{
			return v;
		};
	}

	@property auto get()
	{
		return dg();
	}

	alias get this;

}

/**
	Spawns a function that runs in parallel with the main thread, and returns a value once finished

	Coroutine spawns the aliased function with the parameters it is given in its constructor, runs
	it in parallel, and then captures the result. This result is aliased to coroutine, so accessing
	the coroutine returns the result, unless the coroutine was specifically asked for.

	Coroutine creation is non-blocking, while accessing the result is blocking. Because of this, it
	is best	to start them earlier than needed to run in parallel with the main thread, and then 
	access them	only once needed, as if it were a lazy value.

	It is possible to make coroutines communicate by passing them a channel argument to the function,
	or by passing a Tid and sending messages directly.
*/

struct coroutine(alias fn)
{

	static if(is(ReturnType!fn == void))
		alias bool RetType;
	else 
		alias ReturnType!fn RetType;

	shared helper coro;

	private shared class helper
	{
		static if(!is(RetType == void)) 		shared RetType result;
		static if(ParameterTypeTuple!fn.length) shared ParameterTypeTuple!fn args;
		shared bool ready = false;
		shared Tid tid;
		
		static auto func(shared helper co) 
		{
			static if(is(ReturnType!fn == void))
			{
				static if(ParameterTypeTuple!fn.length) 
					fn(co.args);
				else 
					fn();
			}
			else 
			{
				static if(ParameterTypeTuple!fn.length) 
					co.result = fn(co.args); 
				else 
					co.result = fn();
			}
			co.ready = true;
		}
	}

	static if(ParameterTypeTuple!fn.length) 
	{
		this(ParameterTypeTuple!fn args)
		{				
			pragma(msg, typeof(args), typeof(coro), typeof(coro.args));
			coro = new shared(helper)();
			coro.args = args;
			coro.tid = cast(shared)spawn(&helper.func, coro);
		}
	}

 	static if(!ParameterTypeTuple!fn.length)
	{
		this(int line = __LINE__)
		{
			static assert(ParameterTypeTuple!fn.length == 0, "Cannot use empty-args constructor on function that takes arguments");
			coro = new shared(helper)();
			coro.tid = cast(shared) spawn(&helper.func, coro);		
		}
	}

	static if(!ParameterTypeTuple!fn.length)
	{
		@property static RetType opCall()
		{
			static bool func(int i)
			{
				fn();
				return true;
			}
			coroutine!func c = coroutine!func(0);
			return c;
		}
	} 
	else 
	{
		@property RetType opCall()
		{
			while(!coro.ready)
				Thread.sleep( dur!("msecs")( 1 ) );
			static if(is(RetType == void)) return true;
			else return coro.result;
		}
	}

	alias opCall this;
}


/**
	Channel is a parallel message queue backed by a DList that allows other threads to communicate
	with each other without locks

	Upon instantiation, channel spawns a function that accepts two types of message - a put and a 
	get, or 'send' and 'receive'. With each message, it then tells the internal class instance
	what to do with the list in a manner that emulates a queue. This means that the list access is
	restricted to a single thread, and synchronisation issues are avoided by using the concurrency
	primitives in the standard library, which are backed by an event queue.

	This approach means that the interaction with the message queue is done entirely with messages,
	avoiding any locks at this level or higher.

*/
class channel(T)
{
	private class internal
	{
		shared private DList!T list;
		immutable private Tid tid; 
		immutable private Tid selfTid;
		private bool running;

		enum get{msg = 1}
		enum stop{msg = 2}

		public shared bool isRunning()
		{
			return running;
		}

		public shared void push(T t)
		{
			(cast()list).stableInsertBack!T(t);
		}

		public shared T popFront()
		{
			auto l = (cast(DList!T*)&list);
			T t = l.front();			
			l.stableRemoveFront();
			assert(cast(shared)l == &list);
			return t;
		}

		this()
		{
			tid = cast(immutable)spawn(&run, cast(shared)this);
			selfTid = cast(immutable)thisTid;
			running = true;
		}

		~this()
		{
			std.concurrency.send(cast(Tid)tid, stop.msg);
			running = false;
		}

		public void _send(T t)
		{
			std.concurrency.send(cast(Tid)tid, t);
		}

		@async public T receive()
		{
			/+writeln("Sending from ", &selfTid);
			std.concurrency.send(cast(Tid)tid, get.msg);
			shared T t;
			receiveTimeout(dur!"seconds"(2),(T t1){
				writeln("Receiving t ",t, " at line ", __LINE__);
				t = t1;
				},
				(Variant v)
				{
					writeln(v.type);
				});
			return t;+/
			while((cast()list).empty) Thread.sleep(dur!"msecs"(1));
			return cast(T)(cast(shared)this).popFront();
		}

		@async public T receiveWithTimeout(Duration d)
		{

			import std.datetime;
			auto timeout = Clock.currTime(UTC()) + d;

			while((cast()list).empty)
			{
				if(Clock.currTime>timeout)
					return T.init;
				Thread.sleep(dur!"msecs"(1));
			}
			return cast(T)(cast(shared)this).popFront();
		}

		static void run(shared internal i)
		{
			T t1;
			bool running = true;
			while(i.isRunning()&&running)
			{
				try
				receiveTimeout(dur!"seconds"(1),
					(T t)
					{
						i.push(t);
					},
					(get g)
					{
						Tid* to = cast(Tid*) (&i.selfTid);
						if((cast(DList!T)i.list).empty)
						{													
							std.concurrency.send(*to, cast(immutable)t1);
							return;
						}
						//T t = (cast(DList!T)i.list).front();						
						//(cast(DList!T)i.list).stableRemoveFront();
						t1 = i.popFront();
						std.concurrency.send(*to, t1);
					},
					(stop s)
					{
						running = false;
					});
				catch(OwnerTerminated o)
				{
					return;
				}
			}			
		}
	}

	private internal internals;
	private bool function(T) onReceivef;

	public this()
	{
		internals = new internal();
	}

	public ~this()
	{
		internals.running = false;
	}

	public shared void send(T t)
	{
		if(onReceivef)
		{
			bool r = onReceivef(t);
			if(!r)
				return;
		}
		(cast(internal)internals)._send(t);
	}

	@async public shared T receive()
	{
		return (cast(internal)internals).receive();
	}

	@async public shared T receiveWithTimeout(Duration d)
	{
		return (cast(internal)internals).receiveWithTimeout(d);
	}

	public synchronized void onReceive(bool function (T) fn)
	{
		onReceivef = fn;
	}

}

/**
	A helper function when waiting for a coroutine to avoid the 'var has no effect in statement'
	compiler error when waiting for a coroutine, since the compiler check doesn't account for
	alias this tricks.
*/
auto waitfor(alias fn)()
{
	return fn;
}

/**
	Used to annotate functions to use await with, akin to C#'s async and await. This is not
	required for a function to work, but lets any readers know that the program can be run
	asynchronously.

	Async annotations are ideal for functions which may block for a while, like network
	operations or user-input-reliant processes. However, when awaiting them, the await does
	currently block, unlike C# where it does something more along the lines of a continuation
	where a = await fn() becomes fn().then(a=>...)
*/
class async{}

/**
	An alias to coroutine that also checks for the presence of an @async annotation
*/
template await(alias v, string file = __FILE__, int line = __LINE__)
{	
	static if(staticIndexOf!(async, __traits(getAttributes, v)))
	{
		pragma(msg, "Please note that functions called using 'await' are best given the @async property (function called at "~file~" line "~to!string(line)~")");
	}
	alias coroutine!v await;
}

/**
	An alias to coroutine for stealing google's thunder
*/
alias coroutine go;

/**
	A helper function to automatically create a shared channel of the given type, named after
	golang's channels' 'make(chan type)'
*/
auto make_chan(T)()
{
	return cast(shared) new channel!T;
}