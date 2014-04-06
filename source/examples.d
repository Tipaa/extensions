module source.examples;

import extensions;
import std.concurrency;
import std.container;
import std.algorithm;
import std.conv;
import std.stdio;
import std.string;
import std.range;
import core.time;
import std.file;

int main(string[] args){return 0;}

unittest
{
	//Example of anonymous function in a coroutine.
	//The function must either take an argument or return a value to avoid the
	//'this statement has no effect' error.
	//It is best practice to return a value regardless, as an indicator of
	//completion.
	auto fn = go!(function() {
		for(int i; i < 5; i++) writeln("Coroutine writeln ", i);	
		return ;	
	})();
	foreach(int i; iota(5)) writeln("Main writeln ", i);
}

unittest
{
	//Example of using a channel for communication between coroutines
	//without needing to use the concurrency primitives send(Tid, T...)
	//and receive(T...)
	auto strchan = make_chan!string;

	auto sender = go!(function(shared channel!string c) {
		for(int i = 0; i < 5; i++) c.send("Sending number "~i.to!string);
	})(strchan);

	auto receiver = go!(function(shared channel!string c) {
		string msg;
		do
		{
			//Can use receive() to block until there is a message, or use receiveWithTimeout
			//only block until timeout returning T.init if it has timed out
			msg = c.receiveWithTimeout(dur!"seconds"(2));
			if(msg) writeln("Received message: "~msg);
		} while(msg);
	})(strchan);
}

unittest
{

	//Must use static or declare at top level for the function to work in coroutine
	@async static string getFile(string url)
	{
		return cast(string)read(url);
	}

	await!getFile frontpage = go!getFile("/dev/null");
	writeln("Getting file...");
	//The coroutine is getting the webpage in the background now, but doesn't block

	//The coroutine only now blocks when it is accessed for the first time
	writeln("Got from /dev/null: ",frontpage," (null expected)");

}