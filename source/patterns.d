import std.string;
import std.stdio;
import std.conv;
import std.typetuple;
import std.traits;
//import std.algorithm;

//A simpler version of case_class, for attaching _case_args to a constructor
mixin template case_this(string expr,string args,string sbody)
{
	enum string inject = 
		"public this("~expr~"){
		"~sbody~"
		_case_args = _case_this("~args~");
		}
		struct _case_this {"~expr~";}
		_case_this _case_args;";
	
	mixin(inject);
}

//Provide it with the variables in the class to be pattern matchable and it
//generates the variables and the matching helper, similar to Scala's case
//class matching. Variables can be declared outside, but they cannot then
//be matched
mixin template case_class(string expr)
{
	template genIds()
	{
		static auto splitfields(uint l)(string[] as)
		{
			string[3][l] result;	//[visibility modifier, type, identifier]
			foreach(i,s; as)
			{
				auto split2 = s.strip().lastIndexOf(" ");
				auto split1 = s.strip()[0..split2].strip().indexOf(" ");
				if(split1 < 0) split1 = 0;
				result[i][0] = s.strip()[0..split1];
				result[i][1] = s.strip()[split1..split2];
				result[i][2] = s.strip()[split2+1..$];
			}
			static assert(result[0].length == 3);
			return result.dup;
		}

		//generate constructor
		static string genCode(string[3][] fields)
		{
			string code = "";
			foreach(s;fields)
				static assert(s.length == 3);			
			foreach(s;fields)
				code ~= s[0] ~ " " ~ s[1] ~ " " ~ s[2] ~ ";\n";
			code ~= "public this(";
			foreach(s;fields)
				code ~= s[1] ~ " " ~ s[2] ~ ", ";
			code ~= "int __line = __LINE__)\n{\n";
			foreach(s;fields)
				code ~= "\tthis." ~ s[2] ~ " = " ~ s[2] ~ ";\n";
			code ~= "}";
			return code;
		}

		enum string[] sfields = expr.split(",");
		enum auto fields = splitfields!(sfields.length)(sfields);	
		enum string genIds = genCode(fields);
	}
	mixin(genIds!());
	//handy for debugging
	string gen = genIds!();
}

//Used as the start of a 'match block', as in
//'match!thing { <pattern list> }`
template match(alias x)
{
	enum string postStr = __traits(identifier, (BaseTypeTuple!(typeof(x)))[0]);
	enum string xType = typeof(x).stringof;
	enum string templateStr = xType.indexOf("!")>0?xType[xType.indexOf("!")..$] : "";
	enum string match =
		"static if(__traits(compiles, __currMatch"~postStr~")) __currMatch"~postStr~" = "~__traits(identifier, x) ~ 
		";\nelse " ~ postStr ~ templateStr ~ " __currMatch"~__traits(identifier, (BaseTypeTuple!(typeof(x)))[0])~" = "~__traits(identifier, x)~";";
}

//Creates a string to mixin to create a matcher for a simple pattern, executing
//the body if it matches
template pattern(string s, string sbody)
{
	//currently unused
	enum string makevars = "";//(s.indexOf("(")+1==s.length-1)?"":"typeof(__currMatch._case_args.t) "~s[s.indexOf("(")+1..$-1]~";";

	//ids is an array of all variables to use/assign in the pattern
	static if(s.indexOf("!(")>-1)
		enum string[] ids = s[s.indexOf(")")+2..$-1].split(",");
	else
		enum string[] ids = s[s.indexOf("(")+1..$-1].split(",");

	enum string aliases = makeAliases();

	//set typestring to the string of the whole type (generics included)
	static if(s.indexOf("!(")>-1)	
		enum string typestring = s[0..s.indexOf(")")+1];
	else
		enum string typestring = s[0..s.indexOf("(")];

	//set __currMatchId to "__currMatch" ~ __traits(identifier, supertypeof(type))
	static if(s.indexOf("!")>-1)
		enum string __currMatchId = "__currMatch"~__traits(identifier, (BaseTypeTuple!(mixin(typestring)))[0]);
	else
		enum string __currMatchId = "__currMatch"~__traits(identifier, (BaseTypeTuple!(mixin(typestring)))[0]);
	
	static string makeAliases()
	{
		//I can't quite figure out scoping here, so I repeated these for easy/lazyness
		static if(s.indexOf("!(")>-1)
			enum string typestring = s[0..s.indexOf(")")+1];
		else
			enum string typestring = s[0..s.indexOf("(")];
			
		static if(s.indexOf("!")>-1)
			enum string __currMatchId = "__currMatch"~__traits(identifier, (BaseTypeTuple!(mixin(typestring)))[0]);
		else
			enum string __currMatchId = "__currMatch"~__traits(identifier, (BaseTypeTuple!(mixin(typestring)))[0]);
		
		//empty seed for building the string
		string aliases = "";//"static if(is(typeof(__currMatch)==check)){";
		
		//get a string array of all members of our type to iterate over, so we can extract all the useful variables
		//took a while to find this 'inspired' method
		static if(s.indexOf("!(")>-1)
			const string[] members = mixin(s[0..s.indexOf(")")+1]).tupleof.stringof[6..$-1].split(", ");
		else
			const string[] members = mixin(s[0..s.indexOf("(")]).tupleof.stringof[6..$-1].split(", ");
		
		//generate code to assign each id the value of its respective member
		foreach(n,s; ids)
		{
			aliases ~= "auto "~s~" = (cast("~typestring~")" ~ __currMatchId ~ ")."~members[n]~";\n";
		}
		return aliases;
	}	
	
	//pragma(msg, aliases);
	enum string assignvars = "";//makevars.length?"i = __currMatch._case_args.t":"";
	enum string pattern = "{"~
	//"static if(is(typeof("~__currMatchId~")=="~typestring~")) { "~
	"if(cast("~typestring~")"~__currMatchId~") {"~
	(sbody.indexOf("return ")>-1?"return":"")~"() {
	"~makevars~"
	alias "~typestring~" check;
	"~aliases~" 
	"~assignvars~";
	"~sbody~"}();}
}";
	//To explain, this code first performs a type check (cast(typestring)),
	//then creates a delegate to perform the next stage in to bypass identifier
	//shadowing issues. If the delegate returns a value, return that returned
	//value. Inside the delegate, the types are aliased (but this is currently
	//unused) before being assigned to local values from the id-member mapping
	//in makeAliases(). Then the given code body to perform after the match
	//is inserted, and the delegate finished. The delegate is then immediately
	//evaluated, and finally everything falls back out of scope.
	
}

abstract class Option(T)
{}

//I couldn't get a None to work for all Option!Ts, so I have a None!T for every
//T in Option!T. I guess that's a restriction of using types themselves to
//model constructors, which is in turn a restriction due to using a type system
//expecting pure object orientation
class None(T) : Option!T
{
	mixin case_this!("","","");
}

class Some(T) : Option!T
{
	//Inspired by Scala's case classes
	mixin case_class!"public immutable T t";

	//Nicer printing
	override string toString()
	{
		return "Some!"~T.stringof~"("~to!string(t)~")";
	}
}

abstract class Either(A,B)
{}
class Left(A,B) : Either!(A,B)
{
	mixin case_class!"public immutable A left";
}
class Right(A,B) : Either!(A,B)
{
	mixin case_class!"public immutable B right";
}

							
int testfn()
{
	auto a = new Some!int(1);
	auto n = new None!int();
	
	mixin(match!n);
	{
		//Demonstrating simple extraction
		mixin(pattern!("None!int()",q{writeln("None()");}));
		mixin(pattern!("Some!int(i)",q{writeln("Some(%d)",i);}));
	}
	mixin(match!a);
	{	
		//Can return from a function from within a pattern match
		mixin(pattern!("Some!int(i)","return i + 2;"));
		mixin(pattern!("None!int()","return 0;"));
	}		
	//This is never hit because the previous match clause returns for us
	assert(0);
}

void main()
{
	auto a = new Some!int(1);	

	//These indentation patterns are recommended; I use them for clarity, but
	//they aren't necessary for the templates to work
	mixin(match!a);
	{
		mixin(pattern!("Some!int(i)","auto k = i + 2; writeln(k);"));
	}
		
	auto e = new Left!(int, string)(0);
	auto f = new Right!(int, string)("Right");
	//Testing the Either class
	mixin(match!e);
	{
		mixin(pattern!("Left!(int, string)(l)","writeln(l);"));
		mixin(pattern!("Right!(int, string)(r)","writeln(r);"));
	}
	mixin(match!f);
	{
		mixin(pattern!("Left!(int, string)(l)","writeln(l);"));
		mixin(pattern!("Right!(int, string)(r)","writeln(r);"));
	}
	
	//Embedded matching
	mixin(match!e);
	{
		mixin(pattern!("Left!(int, string)(l1)",q{
			mixin(match!f);
			{
				mixin(pattern!("Left!(int, string)(l2)","writeln(l1,l2);"));
				mixin(pattern!("Right!(int, string)(r2)","writeln(l1,r2,\" as expected.\");")); //Expected outcome
			}
		}));
		mixin(pattern!("Right!(int, string)(r1)",q{
			mixin(match!f);
			{
				mixin(pattern!("Left!(int, string)(l2)","writeln(r1,l2);"));
				mixin(pattern!("Right!(int, string)(r2)","writeln(r1,r2);"));
			}
		}));
	}
	
	int j = testfn(); //Again testing the return capabilities
	writeln(j);
	return;
}
