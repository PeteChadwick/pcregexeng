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
       auto m1 = match( textToMatch, re );
       //re.printProgram();
       auto startTime = clock();

       for( int i=0; i<numLoops; ++i )
       {
           m1 = match( textToMatch, re );
           assert( m1 );
       }
       auto endTime = clock();
       auto ticks = endTime-startTime;
       writefln( "lockstep  (%s): %s ticks  %s ticks/MB (%s)",
                 testName[testNum],ticks, ticks*factor, m1.captures[0] );

       auto btre = btregex( regexStrings[testNum] );
       auto m2 = match( textToMatch, btre );
       startTime = clock();
       for( int i=0; i<numLoops; ++i )
       {
           m2 = match( textToMatch, btre );
           assert( m2 );
       }
       endTime = clock();
       
       ticks = endTime-startTime;
       writefln( "backtrack (%s): %s ticks %s ticks/MB (%s)",
                 testName[testNum], ticks, ticks*factor, m2.captures[0] );

       // We know we aren't using more than 4 captures in this test
       auto m3 = staticMatch!4( textToMatch, btre );
       startTime = clock();
       for( int i=0; i<numLoops; ++i )
       {
           m3 = staticMatch!4( textToMatch, btre );
           assert( m3 );
       }
       endTime = clock();
       
       ticks = endTime-startTime;
       writefln( "staticbt  (%s): %s ticks %s ticks/MB (%s)",
                 testName[testNum], ticks, ticks*factor, m3.captures[0] );

       startTime = clock();
       for( int i=0; i<numLoops; ++i )
       {
           m2 = match( textToMatch, btregex( regexStrings[testNum] ) );
           assert( m2 );
       }
       endTime = clock();
       
       ticks = endTime-startTime;
       writefln( "backtrack (%s): %s ticks %s ticks/MB (%s) (generating regex objects)",
                 testName[testNum], ticks, ticks*factor, m2.captures[0] );

       
       startTime = clock();
       auto stdre = std.regex.regex( regexStrings[testNum] );
       auto m4 = std.regex.match( textToMatch, stdre );
       for( int i=0; i<numLoops; ++i )
       {
           m4 = std.regex.match( textToMatch, stdre );
       }
       endTime = clock();
       
       ticks = endTime-startTime;
       writefln( "std.regex (%s): %s ticks %s ticks/MB (%s)",
                 testName[testNum], ticks, ticks*factor, m4.captures[0]  );

       startTime = clock();
       for( int i=0; i<numLoops; ++i )
       {
           m4 = std.regex.match( textToMatch, std.regex.regex( regexStrings[testNum] ) );
       }
       endTime = clock();
       
       ticks = endTime-startTime;
       writefln( "std.regex (%s): %s ticks %s ticks/MB (%s) (generating regex objects)",
                 testName[testNum], ticks, ticks*factor, m4.captures[0]  );
   }
}

