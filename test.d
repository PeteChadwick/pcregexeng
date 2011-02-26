import std.stdio;
import petec.regexeng;
static import std.regex;
import core.time;
import std.date;
import std.c.time;

void main()
{
    writefln( "Regex test" );
    //return;

   enum string email =
        r"([a-zA-Z0-9._%+-]+)@([a-zA-Z0-9.-]+\.[a-zA-Z]{2,4})";
   enum string emailStr = "User@domain.name.com";

   enum string pathalogical =
       "a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?aaaaaaaaaaaaaaaaaa";
   enum string pathalogicalStr = "aaaaaaaaaaaaaaaaaa";

   int numLoops = 1_000_000;

   auto re = regex( email );
   auto startTime = clock();
   Match!string m;
   for( int i=0; i<numLoops; ++i )
   {
       m = re.match( emailStr );
       assert( m );
   }
   auto endTime = clock();
   writefln( "lockstep: %s ticks (%s)", endTime-startTime, m[0] );

   auto btre = btregex( email );
   startTime = clock();
   for( int i=0; i<numLoops; ++i )
   {
       m = btre.match( emailStr );
       assert( m );
   }
   endTime = clock();

   writefln( "backtrack: %s ticks (%s)", endTime-startTime, m[0] );

   startTime = clock();
   auto stdre = std.regex.regex( email );
   for( int i=0; i<numLoops; ++i )
   {
       std.regex.match( emailStr, stdre );
   }
   endTime = clock();

   writefln( "std.regex: %s ticks", endTime-startTime,  );

   re = regex( pathalogical );
   startTime = clock();
   m = re.match( pathalogicalStr  );
   assert( m );
   endTime = clock();
   writefln( "lockstep pathalogical %s ticks (%s)", endTime-startTime, m[0] );

   btre = btregex( pathalogical );
   startTime = clock();
   m = btre.match( pathalogicalStr  );
   assert( m );
   endTime = clock();
   writefln( "backtrack pathalogical %s ticks (%s)", endTime-startTime, m[0] );

   stdre = std.regex.regex( pathalogical );
   startTime = clock();
   std.regex.match( pathalogicalStr, stdre );
   endTime = clock();

   writefln( "std.regex pathalogical %s ticks", endTime-startTime );

}

