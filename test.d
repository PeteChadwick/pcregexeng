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

   // Text prefix that might match
   string textPrefix;
   for( int i=0; i<10_000; ++i )
   {
       textPrefix ~= "not-an-email-address ";
   }

   // Text prefix that doesn't match at all
   char[] textPrefix2;
   textPrefix2.length = 1024*1024;
   textPrefix2[] = '|';

   string[] testName = 
       [
           "Email",
           "Email",
           "Email prefix 1",
           "Email prefix 2",
           "Pathalogical"
           ];

   string[] regexStrings =
       [
           email,
           "^"~email~"$",
           email,
           email,
           pathalogical
           ];

   string[] regexTextToMatch =
       [
       emailStr,
       emailStr,
       textPrefix.idup~emailStr,
       textPrefix2.idup~emailStr,
       pathalogicalStr
           ];

   int[] repetitions =
       [
           100_000,
           100_000,
           10,
           10,
           1
           ];

   string emailStr2 = textPrefix.idup ~ emailStr;

   for( int testNum=0; testNum<regexStrings.length; ++testNum )
   {
       int numLoops = repetitions[testNum];
       string textToMatch = regexTextToMatch[testNum];
       double charsProced = numLoops*textToMatch.length; 
       double factor = (1024*1024)/charsProced;
       writeln();
       writefln( "Regex: '%s'", regexStrings[testNum] );
       writefln( "Iterations: %s", numLoops );
       writefln( "Text length: %s", textToMatch.length  );
       
       if ( textToMatch.length > 50 )
           writefln( "Text: %s...", textToMatch[0..50] );
       else
           writefln( "Text: %s", textToMatch );

       auto re = lsregex( regexStrings[testNum] );
       //re.printProgram();
       auto startTime = clock();
       Match!string m;
       MatchRange!(string,BackTrackEngine) m2;
       for( int i=0; i<numLoops; ++i )
       {
           m = re.matchAt( textToMatch );
           assert( m );
       }
       auto endTime = clock();
       auto ticks = endTime-startTime;
       writefln( "lockstep  (%s): %s ticks  %s ticks/MB (%s)",
                 testName[testNum],ticks, ticks*factor, m[0] );

       auto btre = btregex( regexStrings[testNum] );

       startTime = clock();
       for( int i=0; i<numLoops; ++i )
       {
           m2 = match( textToMatch, btre );
           //m = btre.matchAt( regexTextToMatch[testNum] );
           assert( m2 );
       }
       endTime = clock();
       
       ticks = endTime-startTime;
       writefln( "backtrack (%s): %s ticks %s ticks/MB (%s)",
                 testName[testNum], ticks, ticks*factor, m2.captures[0] );

       // We know we aren't using more than 4 captures in this test
       Match!(string,4) staticMatch;
       startTime = clock();
       for( int i=0; i<numLoops; ++i )
       {
           btre.matchAt( textToMatch, staticMatch );
           assert( staticMatch );
       }
       endTime = clock();
       
       ticks = endTime-startTime;
       writefln( "staticbt  (%s): %s ticks %s ticks/MB (%s)",
                 testName[testNum], ticks, ticks*factor, staticMatch[0] );

       
       startTime = clock();
       auto stdre = std.regex.regex( regexStrings[testNum] );
       for( int i=0; i<numLoops; ++i )
       {
           std.regex.match( textToMatch, stdre );
       }
       endTime = clock();
       
       ticks = endTime-startTime;
       writefln( "std.regex (%s): %s ticks %s ticks/MB",
                 testName[testNum], ticks, ticks*factor  );
   }
}

