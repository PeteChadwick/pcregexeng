/*
  Regex engine based on ideas in Russ Cox's regex article:
  http://swtch.com/~rsc/regexp/regexp2.html
  Some implementation details inspired by std.regex
  Range API based on std.regex

  Author: Peter Chadwick

  License: http://www.boost.org/LICENSE_1_0.txt

  Revision History:

     2010-10    Started
     2011-02    Replaced recursive calls with loops
     2011-02    Add backtracking engine
*/

module petec.regexeng;

import std.array;
import std.stdio;
import std.algorithm;
import std.utf;
import std.conv;
import std.bitmanip;
import std.traits;
import std.typecons;
import std.format;
import std.ctype;

/*
  Parser

  Notes:
  Priority: kleene star (repetition), concatenation, alternation

  expr -> alternation
  alternation -> concat | concat '|' concat
  concat -> rep | rep rep
  rep -> atom | atom* | atom+ | atom? | atom{m} | atom{m,n} | atom{m,n}
  atom -> char | group | set
  group -> ( expr )
  set -> [ chars ]

 */

/*
  Instructions:
*/

private // Module only stuff
{
    // The opcodes wont take many bits, it may be sensible to use
    // bitfields and share space with stateNumber. stateNumber can
    // probably be 16 bits or less?

    enum REInst
    {
        Char,
        IChar,
        AnyChar,
        CharRange,
        ICharRange,
        CharBitmap,
        Save,
        Split,
        Jump,
        Match,
        BOL, // multiline
        EOL,
        BOT,
        EOT,
        WordBoundary,
        LookAround
    }

    struct Inst
    {
        REInst type;
        // Statenumber is used to keep track of generations, it's not
        // used by the backtracking engine
        size_t stateNumber;
    }

    
    struct InstChar
    {
        Inst inst = { REInst.Char, 0 };
        alias inst this;
        dchar c;
    }

    struct InstIChar
    {
        Inst inst = { REInst.IChar, 0 };
        alias inst this;
        dchar c;
    }

    struct InstAnyChar
    {
        Inst inst = { REInst.AnyChar, 0 };
        alias inst this;
    }
    
    struct InstCharRange
    {
        Inst inst = { REInst.CharRange, 0 };
        alias inst this;
        Span!dchar span;
    }

    struct InstICharRange
    {
        Inst inst = { REInst.ICharRange, 0 };
        alias inst this;
        Span!dchar span;
    }

    struct InstBOL
    {
        Inst inst = { REInst.BOL, 0 };
        alias inst this;
    }
    
    struct InstEOL
    {
        Inst inst = { REInst.EOL, 0 };
        alias inst this;
    }

    struct InstBOT
    {
        Inst inst = { REInst.BOT, 0 };
        alias inst this;
    }
    
    struct InstEOT
    {
        Inst inst = { REInst.EOT, 0 };
        alias inst this;
    }

    struct InstWordBoundary
    {
        Inst inst = { REInst.WordBoundary, 0 };
        alias inst this;
        bool positiveFlag = true;
    }

    struct InstLookAround
    {
        Inst inst = { REInst.LookAround, 0 };
        alias inst this;
        bool ahead = true;
        bool positive = true;
        int distance = 0;
        size_t jumpLoc = 0;
    }

    struct InstCharBitmap
    {
        Inst inst = { REInst.CharBitmap, 0 };
        alias inst this;
        byte[16] bitmap;

        bool opIndex( uint i )
        {
            int byteNum = i / 8;
            int bitNum = i % 8;

            int bitMask = 1 << bitNum;

            if ( bitMask & bitmap[byteNum] )
                return true;
            else
                return false;
        }

        void opIndexAssign( bool state, uint i )
        {
            int byteNum = i / 8;
            int bitNum = i % 8;

            int bitMask = 1 << bitNum;
            
            if ( state )
                bitmap[byteNum] |= bitMask;
            else
                bitmap[byteNum] &= ~bitMask;
        }
    }

    unittest
    {
        InstCharBitmap bitmap;
        

        for( int i=0; i<128; ++i )
        {
            if ( i % 2 == 0 )
            {
                bitmap[i] = true;
            }
        }

        for( int i=0; i<128; ++i )
        {
            if ( i % 2 == 0 )
                assert( bitmap[i] );
            else
                assert( !bitmap[i] );
        }
    }

    struct InstSplit
    {
        Inst inst = { REInst.Split, 0 };
        alias inst this;
        size_t locPref;
        size_t locSec;
    }

    struct InstMatch
    {
        Inst inst = { REInst.Match, 0 };
        alias inst this;
    }

    struct InstJump
    {
        Inst inst = { REInst.Jump, 0 };
        alias inst this;
        size_t loc;
    }

    struct InstSave
    {
        Inst inst = { REInst.Save, 0 };
        alias inst this;
        size_t num;
    }

    struct Span(T)
    {
        T start;
        T end;

        this( T start, T end )
        {
            this.start = start;
            this.end = end;
        }

        string toString()
        {
            auto writer = appender!string();

            if ( start >= ' ' && start <= '~' ||
                 start > 7F && start <= 0xe0fff )
                formattedWrite( writer, "%s", start );
            else
                formattedWrite( writer, "0x%x", start );

            formattedWrite( writer, "%s", " - " );

            if ( end >= ' ' && end <= '~' ||
                 end > 7F && end <= 0xe0fff )
                formattedWrite( writer, "%s", end );
            else
                formattedWrite( writer, "0x%x", end );
                
            return writer.data;
        }
    }

    void AddSpan(T)( ref Span!T[] spans, Span!T span )
    {
        // assert span.start <= span.end

        size_t i=0;
        while( i<spans.length && spans[i].start < span.start )
            ++i;

        Span!T[] startSlice, endSlice;

        startSlice = spans[0..i];

        // Should this span be merged with previous span?
        if ( i > 0 && spans[i-1].end  >= span.start - 1 )
        {
            span.start = spans[i-1].start;
            startSlice = spans[0..i-1];
        }

        size_t j=i;
        while( j<spans.length && spans[j].end < span.end )
            ++j;

        endSlice = spans[j..$];
        // Should this span be merged with the next span
        if ( j < spans.length && spans[j].start <= span.end + 1 )
        {
            span.end = spans[j].end;
            endSlice=spans[j+1..$];
        }

        spans = startSlice ~ span ~ endSlice;
    }

    void SubSpan(T)( ref Span!T[] spans, Span!T span )
    {
        Span!T[] spans2;

        foreach( ref Span!T curSpan; spans )
        {
            // Add parts of curSpan outside of span to spans2
            // (1[2]3) -> []
            // ([123]) -> []
            // (1[2)3] -> [3]
            // [1(2]3) -> [1]
            // [1](23) -> [1]

            // If span overlaps
            if ( span.end >= curSpan.start && span.start <= curSpan.end )
            {
                // Start Piece ( must be first )
                if ( span.start != T.min && span.start > curSpan.start )
                    spans2 ~= Span!T( curSpan.start, span.start - 1 );

                // End piece
                if ( span.end != T.max && span.end < curSpan.end )
                    spans2 ~= Span!T( span.end + 1, curSpan.end );
            }
            else
            {
                spans2 ~= curSpan;
            }
        }

        // Swap with new spans
        spans = spans2;
    }

    unittest
    {
        alias Span!dchar dspan;

        dspan[] spans, spans2;

        AddSpan( spans, dspan( '0', '2' ) );
        AddSpan( spans, dspan( '7', '9' ) );
        assert( spans == [ dspan( '0', '2' ), dspan( '7', '9' ) ] );

        spans2 = spans.dup;
        AddSpan( spans2, dspan( '1', '4' ) );
        assert( spans2 == [ dspan( '0', '4' ), dspan( '7', '9' ) ] );

        spans2 = spans.dup;
        AddSpan( spans2, dspan( '5', '8' ) );
        assert( spans2 == [ dspan( '0', '2' ), dspan( '5', '9' ) ] );

        spans2 = spans.dup;
        AddSpan( spans2, dspan( '2', '7' ) );
        assert( spans2 == [ dspan( '0', '9' ) ] );

        spans2 = spans.dup;
        AddSpan( spans2, dspan( '4', '5' ) );
        assert( spans2 == [ dspan( '0', '2' ), dspan( '4', '5' ), dspan( '7', '9' ) ] );

        spans2 = spans.dup;
        AddSpan( spans2, dspan( '3', '4' ) );
        assert( spans2 == [ dspan( '0', '4' ), dspan( '7', '9' ) ] );

        spans2 = spans.dup;
        SubSpan( spans2, dspan( '5', '8' ) );
        assert( spans2 == [ dspan( '0', '2' ), dspan( '9', '9' ) ] );
    }


    bool isWordChar(String)( String s, size_t charPos )
    {
        if ( charPos == size_t.max )
            return false;
        if ( charPos >= s.length )
            return false;
        
        dchar c = decode( s, charPos );
        
        if ( c >= '0' && c <= '9' ||
             c >= 'A' && c <= 'Z' ||
             c >= 'a' && c <= 'z' ||
             c == '_' )
            return true;
        else
            return false;
    }

    bool isNewLineChar(String)( String s, size_t charPos )
    {
        if ( charPos == size_t.max ) // BOT
            return true;
        if ( charPos >= s.length ) // EOT
            return true;

        dchar c = decode( s, charPos );
        
        if ( c == '\n' || c == '\r' )
            return true;
        
        return false;
    }
}

void printProgram( byte[] program )
{
    size_t pos;
    while( pos < program.length )
    {
        writef( "%s\t", pos );
        REInst* instType = cast(REInst*)&program[pos];
        final switch( *instType )
        {
        case REInst.Char:
            InstChar* inst = cast(InstChar*)&program[pos];
            writefln( "Char %s", inst.c );
                
            pos += InstChar.sizeof;
            break;

        case REInst.IChar:
            InstIChar* inst = cast(InstIChar*)&program[pos];
            writefln( "IChar %s", inst.c );
                
            pos += InstIChar.sizeof;
            break;

        case REInst.CharRange:
            InstCharRange* inst = cast(InstCharRange*)&program[pos];
            writefln( "CharRange %s", inst.span );
                
            pos += InstCharRange.sizeof;
            break;

        case REInst.ICharRange:
            InstICharRange* inst = cast(InstICharRange*)&program[pos];
            writefln( "ICharRange %s", inst.span );
                
            pos += InstICharRange.sizeof;
            break;

        case REInst.CharBitmap:
            InstCharBitmap* inst = cast(InstCharBitmap*)&program[pos];
            Span!dchar[] spans;
            write( "CharBitmap" );
            for( int i=0; i<128; ++i )
            {
                if( (*inst)[i] )
                    spans.AddSpan( Span!dchar( i, i ) );
            }

            foreach( Span!dchar span; spans )
                writef( ", %s", span );
            writefln("");

            pos += InstCharBitmap.sizeof;
            break;

        case REInst.AnyChar:
            writeln( "AnyChar" );
                
            pos += InstAnyChar.sizeof;
            break;

        case REInst.Save:
            InstSave* inst = cast(InstSave*)&program[pos];
            writefln( "Save %s", inst.num );

            pos += InstSave.sizeof;
            break;

        case REInst.Split:
            InstSplit* inst = cast(InstSplit*)&program[pos];
            writefln( "Split %s %s", inst.locPref, inst.locSec );

            pos += InstSplit.sizeof;
            break;

        case REInst.Jump:
            InstJump* inst = cast(InstJump*)&program[pos];
            writefln( "Jump %s", inst.loc );

            pos += InstJump.sizeof;
            break;

        case REInst.Match:
            writefln( "Match" );
            pos += InstMatch.sizeof;
            break;

        case REInst.BOL:
            writefln( "BOL" );
            pos += InstBOL.sizeof;
            break;

        case REInst.EOL:
            writefln( "EOL" );
            pos += InstEOL.sizeof;
            break;

        case REInst.BOT:
            writefln( "BOT" );
            pos += InstBOT.sizeof;
            break;

        case REInst.EOT:
            writefln( "EOT" );
            pos += InstEOT.sizeof;
            break;

        case REInst.WordBoundary:
            InstWordBoundary* inst = cast(InstWordBoundary*)&program[pos];
            writefln( "Word Boundary positiveFlag:%s", inst.positiveFlag );
            pos += InstWordBoundary.sizeof;
            break;


        case REInst.LookAround:
            InstLookAround* inst = cast(InstLookAround*)&program[pos];
            writefln( "LookAround ahead:%s positive:%s distance:%s", inst.ahead, inst.positive, inst.distance );
            pos += InstLookAround.sizeof;
            break;
        }
    }
}

void enumerateStates( byte[] program, out size_t numStates )
{
    size_t pos;
    while( pos < program.length )
    {
        Inst* inst = cast(Inst*)&program[pos];
        inst.stateNumber = numStates;
        ++numStates;

        final switch( inst.type )
        {
        case REInst.Char:
            pos += InstChar.sizeof;
            break;

        case REInst.IChar:
            pos += InstIChar.sizeof;
            break;

        case REInst.CharRange:
            pos += InstCharRange.sizeof;
            break;

        case REInst.ICharRange:
            pos += InstICharRange.sizeof;
            break;

        case REInst.CharBitmap:
            pos += InstCharBitmap.sizeof;
            break;

        case REInst.AnyChar:
            pos += InstAnyChar.sizeof;
            break;

        case REInst.Save:
            pos += InstSave.sizeof;
            break;

        case REInst.Split:
            pos += InstSplit.sizeof;
            break;

        case REInst.Jump:
            pos += InstJump.sizeof;
            break;

        case REInst.Match:
            pos += InstMatch.sizeof;
            break;

        case REInst.BOL:
            pos += InstBOL.sizeof;
            break;

        case REInst.EOL:
            pos += InstEOL.sizeof;
            break;

        case REInst.BOT:
            pos += InstBOT.sizeof;
            break;

        case REInst.EOT:
            pos += InstEOT.sizeof;
            break;

        case REInst.WordBoundary:
            pos += InstWordBoundary.sizeof;
            break;

        case REInst.LookAround:
            pos += InstLookAround.sizeof;
            break;
        }
    }
}


struct RegexParser
{
    struct RegexFlags
    {
        mixin( bitfields!(
                   bool, "CaseInsensitive", 1,
                   bool, "MultiLine", 1,
                   bool, "Ungreedy", 1,  // unused
                   bool, "FixedLength", 1, // For lookbehind
                   uint, "", 4 ));
    }

    int fixedCharStack[];
    private void sumFixedCharStack()
    {
        int sum=0;
        size_t idx = fixedCharStack.length;
        while( idx > 0 )
        {
            int num = fixedCharStack[idx-1];
            fixedCharStack.length -= 1; // pop

            if ( num >= 0 )
                sum += fixedCharStack[idx-1];
            else
                break;

            --idx;
        }

        fixedCharStack ~= sum;
    }

    private int topFixedCharStack()
    {
        if ( fixedCharStack.length ==0 )
            return 0;
        else
            return fixedCharStack[$-1];
    }
    

    // Make flags a default parameter?
    this(String)( String s, RegexFlags reFlags )
    {
        //RegexFlags reFlags;
        reFlags.CaseInsensitive = false;
        reFlags.MultiLine = false;
        reFlags.Ungreedy = false;

        fixedCharStack = [];

        // Add ungreedy .* at the beginning to find matches after the
        // first character
        // a split d, b
        // b anychar
        // c jump a
        // d ...

        // This should be optional match vs search perhaps
        mixin( MakeREInst( "InstSplit", "splitInst" ) );
        splitInst.locPref = InstSplit.sizeof + InstAnyChar.sizeof + InstJump.sizeof;
        splitInst.locSec = InstSplit.sizeof;
        mixin( MakeREInst( "InstAnyChar", "anyCharInst" ) );
        mixin( MakeREInst( "InstJump", "jumpInst" ) );
        jumpInst.loc = 0;
        
        program = splitInstBuf ~ anyCharInstBuf ~ jumpInstBuf;

        size_t endUngreedyStar = program.length;

        program.length += InstSave.sizeof;
        InstSave* instSave = cast(InstSave*)&program[$-InstSave.sizeof];
        *instSave = InstSave();
        instSave.num = 0;
        ++numCaptures;

        parseRegex( s, reFlags );

        // If the first instruction is a BOT remove ungreedyStar
        size_t firstInstPos = endUngreedyStar + InstSave.sizeof;
        Inst* firstInst = cast(Inst*)&program[firstInstPos];
        if ( firstInst.type == REInst.BOT )
        {
            program = program[endUngreedyStar..$];
            fixOffsets( program, 0, -endUngreedyStar );
        }

        assert( fixedCharStack.length == 1 );
        //writefln( "regex: %s, min length: %s stacklen = %s", s, topFixedCharStack(), fixedCharStack.length );

        program.length += InstSave.sizeof;
        instSave = cast(InstSave*)&program[$-InstSave.sizeof];
        *instSave = InstSave();
        instSave.num = 1;

        program.length += InstMatch.sizeof;
        InstMatch* instMatch = cast(InstMatch*)&program[$-InstMatch.sizeof];
        *instMatch = InstMatch();
    }

    byte[] program;

    size_t numCaptures=0;
    size_t[] parserCaptureStack;

    void fixOffsets( byte[] prog, size_t pos, int shift )
    {
        while( pos < prog.length )
        {
            REInst* instType = cast(REInst*)&prog[pos];
            final switch( *instType )
            {
            case REInst.Char:
                pos += InstChar.sizeof;
                break;

            case REInst.IChar:
                pos += InstIChar.sizeof;
                break;

            case REInst.CharRange:
                pos += InstCharRange.sizeof;
                break;

            case REInst.ICharRange:
                pos += InstICharRange.sizeof;
                break;

            case REInst.CharBitmap:
                pos += InstCharBitmap.sizeof;
                break;

            case REInst.AnyChar:
                pos += InstAnyChar.sizeof;
                break;

            case REInst.Save:
                pos += InstSave.sizeof;
                break;

            case REInst.Split:
                InstSplit* inst = cast(InstSplit*)&prog[pos];

                inst.locPref += shift;
                inst.locSec += shift;

                pos += InstSplit.sizeof;
                break;

            case REInst.Jump:
                InstJump* inst = cast(InstJump*)&prog[pos];
                inst.loc += shift;

                pos += InstJump.sizeof;
                break;

            case REInst.Match:
                pos += InstMatch.sizeof;
                break;

            case REInst.BOL:
                pos += InstBOL.sizeof;
                break;

            case REInst.EOL:
                pos += InstEOL.sizeof;
                break;

            case REInst.BOT:
                pos += InstBOT.sizeof;
                break;

            case REInst.EOT:
                pos += InstEOT.sizeof;
                break;

            case REInst.WordBoundary:
                pos += InstWordBoundary.sizeof;
                break;

            case REInst.LookAround:
                pos += InstLookAround.sizeof;
                break;

            }
        }
    }


    static string MakeREInst( string instType, string instName )
    {
        string result =
            "byte["~instType~".sizeof] "~instName~"Buf;"~
            instType~"* "~instName~" = cast("~instType~"*)&"~instName~"Buf[0];"~
            "*"~instName~" = "~instType~"();";
        
        return result;
    }


    /*
      Need new end of program, pass as a ref argument
     */
    size_t parseRegex(String)( String pattern, ref RegexFlags reFlags )
    {
        fixedCharStack ~= -1;

        size_t nextStart = 0;
        size_t progConcatStart = program.length;
        nextStart = parseConcat( pattern, reFlags );

        sumFixedCharStack();

        while( nextStart != pattern.length && pattern[nextStart] == '|' )
        {
            // Create a split instruction
            mixin( MakeREInst( "InstSplit", "splitInst" ) );
            splitInst.locPref = progConcatStart;
            splitInst.locSec = program.length + InstJump.sizeof; // After the jump inst that will be appended
            program = program[0..progConcatStart]
                ~ splitInstBuf
                ~ program[progConcatStart..$];
            fixOffsets( program, progConcatStart, InstSplit.sizeof );

            // Create jump instruction
            size_t jumpInstPos = program.length;
            mixin( MakeREInst( "InstJump", "jumpInst" ) );
            program ~= jumpInstBuf;
            // We'll need to set the jump target after we parse the next concat

            fixedCharStack ~= -1;

            // Parse next concat
            nextStart++;
            nextStart += parseConcat( pattern[nextStart..$], reFlags );

            sumFixedCharStack();
            // Check that all alternations are the same length
            if ( reFlags.FixedLength && fixedCharStack[$-1] != fixedCharStack[$-2] )
                throw new Exception( "Lookbehind expression not fixed length" );
            
            fixedCharStack.length -= 1; // pop

            // Set jump target
            jumpInst = cast(InstJump*)&program[jumpInstPos]; // Get the jump instruction in the program
            jumpInst.loc = program.length;
        }

        return nextStart;
    }

    size_t parseConcat(String)( String pattern, ref RegexFlags reFlags )
    {
        size_t nextStart = 0;

        fixedCharStack ~= -1;

        // Keep going until we reach the end or an alternation or a group
        while ( nextStart != pattern.length && pattern[nextStart] != '|' && pattern[nextStart] != ')' )
        {
            nextStart += parseRep( pattern[nextStart..$], reFlags );
        }

        sumFixedCharStack();

        return nextStart;
    }

    size_t parseRep(String)( String pattern, ref RegexFlags reFlags )
    {
        fixedCharStack ~= -1;

        size_t start = 0;
        size_t progAtomStart = program.length;
        size_t end = parseAtom( pattern, reFlags );


        sumFixedCharStack();
    
        // check rep character
        if ( end == pattern.length || pattern[end] == '|' || pattern[end] == ')' )
        {
            // ok
        }
        else if ( pattern[end] == '*' )
            // a : split b, d
            // b : atom
            // c : jump a
            // d : ...
        {
            if ( reFlags.FixedLength )
                throw new Exception( "Lookbehind expression not fixed length" );

            fixedCharStack[$-1] = 0; // min = 0 * atom

            bool isGreedy = true;
            if ( pattern.length > end+1 && pattern[end+1] == '?' )
                isGreedy = false;
            mixin( MakeREInst( "InstSplit", "splitInst" ) );
            if ( isGreedy )
            {
                splitInst.locPref = progAtomStart;
                splitInst.locSec = program.length + InstJump.sizeof;
            }
            else
            {
                splitInst.locSec = progAtomStart;
                splitInst.locPref = program.length + InstJump.sizeof;
            }
            program = program[0..progAtomStart]
                ~ splitInstBuf
                ~ program[progAtomStart..$];
            // Note: this will also fix the offsets of the split
            // instruction itself
            fixOffsets( program, progAtomStart, InstSplit.sizeof );

            // Jump
            program.length += InstJump.sizeof;
            InstJump* instJump = cast(InstJump*)&program[$-InstJump.sizeof];
            *instJump = InstJump();
            instJump.loc = progAtomStart; // Where split will now be

            end += 1;
            if ( !isGreedy )
                end += 1;
        }
        else if ( pattern[end] == '+' )
            // a : atom
            // b : split a, c
            // c : ...
        {
            if ( reFlags.FixedLength )
                throw new Exception( "Lookbehind expression not fixed length" );

            bool isGreedy = true;
            if ( pattern.length > end+1 && pattern[end+1] == '?' )
                isGreedy = false;

            mixin( MakeREInst( "InstSplit", "splitInst" ) );
            if ( isGreedy )
            {
                splitInst.locPref = progAtomStart;
                splitInst.locSec = program.length + InstSplit.sizeof;
            }
            else
            {
                splitInst.locSec = progAtomStart;
                splitInst.locPref = program.length + InstSplit.sizeof;
            }
            program ~= splitInstBuf;

            end += 1;
        }
        else if ( pattern[end] == '?' )
            // a : split b, c
            // b : atom
            // c : ...
        {
            if ( reFlags.FixedLength )
                throw new Exception( "Lookbehind expression not fixed length" );

            fixedCharStack[$-1] = 0; // min = 0 * atom

            mixin( MakeREInst( "InstSplit", "splitInst" ) );
            splitInst.locPref = progAtomStart;
            splitInst.locSec = program.length;
            program = program[0..progAtomStart]
                ~ splitInstBuf
                ~ program[progAtomStart..$];
            // Note: this will also fix the offsets of the split
            // instruction itself
            fixOffsets( program, progAtomStart, InstSplit.sizeof );

            end += 1;
        }
        else if ( pattern[end] == '{' )
            // expand to {m,n} to m(n-m)?
            // a : atom 1
            // b : atom 2
            // c : atom 3
            // d : atom m
            // e : split f, g
            // f : atom m + 1
            // g : split h, i
            // h : atom m + 2
            // ..
            //     atom n
        {
            if ( reFlags.FixedLength )
                throw new Exception( "Lookbehind expression not fixed length" );

            fixedCharStack[$-1] = 0; // min = 0 * atom (say)

            end += 1;

            int readDigits( int end )
            {
                size_t endDigits = end;
            
                // read digits
                while( endDigits < pattern.length )
                {
                    size_t new_end=endDigits;
                    dchar c = decode( pattern, new_end );

                    if ( c >= '0' && c <= '9' )
                        endDigits = new_end;
                    else
                        break;
                }

                return endDigits;
            }

            int endDigits = readDigits( end );

            if ( endDigits >= pattern.length )
                throw new Exception( "Unclosed '{' in pattern" );

            if ( endDigits == end )
                throw new Exception( "Expected minimum in '{'" );

            int minimum = to!int( pattern[end..endDigits] );
            int maximum = -1; // exactly m

            // read comma?
            end = endDigits;

            dchar c = decode( pattern, end ); // advance end
            
            if ( c == ',' )
            {
                // read digits?
                endDigits = readDigits( end );
                
                if ( endDigits >= pattern.length )
                    throw new Exception( "Unclosed '{' in pattern" );

                if ( endDigits == end )
                    maximum = -2;       // no upper limit
                else
                    maximum = to!int( pattern[end..endDigits] );

                end = endDigits;
                
                // read }
                c = decode( pattern, end ); // advance end

                
                if ( c != '}' )
                    throw new Exception( "Expected '}'" );
            }
            else if ( c != '}' )
            {
                throw new Exception( "Expected '}'" );
            }

            //writefln( "Minimum = %s, maximum = %s", minimum, maximum );

            if ( maximum > 0 && minimum > maximum )
                throw new Exception( "minimum > maximum" );

            byte[] atomChunk = program[progAtomStart..$];

            // Remove atom chunk from program
            program = program[0..progAtomStart];

            for( int i=0; i<minimum; ++i )
            {
                int insertPos = program.length;
                program ~= atomChunk;
                fixOffsets( program,
                            insertPos,
                            insertPos - progAtomStart );
            }
            for( int j=minimum; j<maximum; ++j )
            {
                mixin( MakeREInst( "InstSplit", "splitInst" ) );
                splitInst.locPref = program.length + InstSplit.sizeof;
                splitInst.locSec = splitInst.locPref + atomChunk.length;
                
                program ~= splitInstBuf;

                int insertPos = program.length;
                program ~= atomChunk;
                fixOffsets( program,
                            insertPos,
                            insertPos - progAtomStart );
            }
        }

        //writefln( "rep = %s", pattern[start..end] );
        return end;
    }

    size_t parseGroup(String)( String pattern, ref RegexFlags reFlags )
    {
        size_t start = 0;
        size_t end=1; // take leading '(' into account

        // TODO: Use flags instead of bools?
        bool capturingGroup = true;
        bool lookAroundGroup = false;
        bool positiveLookAround = true;
        bool lookAhead = true;

        RegexFlags newReFlags = reFlags;

        size_t newEnd = end;
        if ( decode( pattern, newEnd ) == '?' )
        {
            // TODO: Look for flags
            // TODO: Make this a function so it can be called from the constructor
            // to set the initial flags e.g. Regex( "Bob", "i" );
            dchar c = decode( pattern, newEnd );
            bool flagMode = true;

            while( c != ':' && c != ')' && c != '=' && c != '!' && c != '<' )
            {
                if ( c == '-' )
                {
                    flagMode = false;
                    c = decode( pattern, newEnd );
                }

                if ( c == 'i' )
                    newReFlags.CaseInsensitive = flagMode;

                if ( c == 'm' )
                    newReFlags.MultiLine = flagMode;

                c = decode( pattern, newEnd );
            }

            if ( c == ':' )
                capturingGroup = false;
            else if ( c == '=' ) // lookahead
            {
                capturingGroup = false;
                lookAroundGroup = true;
                positiveLookAround = true;
            }
            else if ( c == '!' ) // negative lookahead
            {
                capturingGroup = false;
                lookAroundGroup = true;
                positiveLookAround = false;
            }
            else if ( c == '<' ) // lookbehind
            {
                c = decode( pattern, newEnd );
                if ( c == '=' )
                {
                    capturingGroup = false;
                    lookAroundGroup = true;
                    positiveLookAround = true;
                    lookAhead = false;
                }
                else if ( c == '!' )
                {
                    capturingGroup = false;
                    lookAroundGroup = true;
                    positiveLookAround = false;
                    lookAhead = false;
                }
                else
                    throw new Exception( "Invalid lookbehind expression" );
            }
            else if ( c == ')' )
            {
                // Set flags for enclosing scope
                reFlags = newReFlags;
                // We're done
                return newEnd;
            }
            else
                throw new Exception( "Unknown group flag" );
            
            end = newEnd;
        }

        InstSave* instSave;
        if ( capturingGroup )
        {
            program.length += InstSave.sizeof;
            instSave = cast(InstSave*)
                &program[program.length-InstSave.sizeof];
            *instSave = InstSave();
            instSave.num = 2*numCaptures;
            parserCaptureStack ~= numCaptures; // Push numCaptures onto stack
            ++numCaptures;
        }

        size_t lookAroundOffset;
        if ( lookAroundGroup )
        {
            mixin( MakeREInst( "InstLookAround", "lookAroundInst" ) );
            lookAroundInst.ahead = lookAhead;
            lookAroundInst.positive = positiveLookAround;

            lookAroundOffset = program.length;
            program ~= lookAroundInstBuf;
            fixedCharStack ~= -1;
        }

        end += parseRegex( pattern[end..$], newReFlags );
        if ( end == pattern.length )
        {
            throw new Exception( "parseGroup error: Expected )" );
        }
        if ( pattern[end] != ')' )
        {
            throw new Exception( "parseGroup error: Expected ) found" ~ to!string(pattern[end]) );
        }

        if ( capturingGroup )
        {
            // save instruction
            program.length += InstSave.sizeof;
            instSave = cast(InstSave*)
                &program[program.length-InstSave.sizeof];
            *instSave = InstSave();
            instSave.num = 2*parserCaptureStack[$-1] + 1; // get last pushed capture
            parserCaptureStack.length -= 1; // pop stack
        }

        if ( lookAroundGroup )
        {
            sumFixedCharStack();
            InstLookAround* lookAroundInst = cast(InstLookAround*)&program[lookAroundOffset];
            if ( !lookAroundInst.ahead )
            {
                lookAroundInst.distance = topFixedCharStack();
            }
            fixedCharStack.length -= 1; // pop
            mixin( MakeREInst( "InstMatch", "matchInst" ) );

            program ~= matchInstBuf;
            lookAroundInst.jumpLoc = program.length;
        }

        end++;

        //writefln( "group = %s", pattern[0..end] );

        return end;
    }

    // We need a set regex
    size_t parseSet(String)( String pattern, ref RegexFlags reFlags )
    {
        fixedCharStack ~= 1;

        size_t start = 0;
        size_t end=1; // take leading '[' into account

        Span!dchar[] charRanges;

        bool isNegSet = false;
        if ( pattern[end] == '^' )
        {
            isNegSet = true;
            end += 1;
        }

        size_t patternStart = end;

        dchar c;
        dchar prevc;
        while( end < pattern.length && pattern[end] != ']' )
        {
            prevc = c;
            c = decode( pattern, end ); // Advances end
            if ( c == '-' && end > patternStart )
            {
                // get next character
                c = decode( pattern, end );
                
                // if '-' is the last character, add it instead of a span
                if ( c == ']' )
                {
                    AddSpan( charRanges, Span!dchar( prevc, prevc ) );
                    end -= 1; // rewind so we parse the ']'
                }
                else
                    AddSpan( charRanges, Span!dchar( prevc, c ) );
            }
            else if ( c == '\\' )
            {
                c = decode( pattern, end );
                parseEscapedChar( c, charRanges, reFlags );
            }
            else
                AddSpan( charRanges, Span!dchar( c, c ) );
        }

        if ( pattern[end] != ']' )
        {
            throw new Exception( "Expected closing ] in pattern" );
        }
        end += 1; // trailing ']'
        
        if ( isNegSet )
        {
            // Subtract ranges from a full range
            Span!dchar[] fullRange;
            AddSpan( fullRange, Span!dchar( 0, dchar.max ) );
            foreach( ref Span!dchar span; charRanges )
            {
                SubSpan( fullRange, span );
            }
            charRanges = fullRange;
        }

        // can we use a CharBitmap?
        if ( charRanges.length > 0 &&
             charRanges[0].start >= 0 &&
             charRanges[$-1].end < 128 )
        {
            mixin( MakeREInst( "InstCharBitmap", "charBitmapInst" ) );
            foreach( Span!dchar span; charRanges )
            {
                for( dchar i=span.start; i<= span.end; ++i )
                {
                    if ( reFlags.CaseInsensitive )
                    {
                        (*charBitmapInst)[tolower(i)] = true;
                        (*charBitmapInst)[toupper(i)] = true;
                    }
                    else
                    {
                        (*charBitmapInst)[i] = true;
                    }
                }
            }

            program ~= charBitmapInstBuf;

            return end;
        }

        size_t setProgPos = program.length;
        
        // Calculate the length of the program (to find where to jump to)
        size_t progLen = 0;
        foreach( ref Span!dchar charRange; charRanges )
        {
            // InstChar/InstRange and case insensitive variants are
            // the same size, so don't bother checking flag

            if ( charRange.start == charRange.end )
                progLen += InstChar.sizeof;
            else
                progLen += InstCharRange.sizeof;
        }

        progLen += (charRanges.length - 1)*(InstSplit.sizeof + InstJump.sizeof );

        foreach( int i, ref Span!dchar charRange; charRanges[0..$] )
        {
            bool isLastRange = i == charRanges.length - 1;

            if ( !isLastRange )
            {
                // Split
                mixin( MakeREInst( "InstSplit", "splitInst" ) );
                splitInst.locPref = program.length + InstSplit.sizeof;
                // Need to add size of Char or CharRange
                splitInst.locSec = program.length + InstSplit.sizeof + InstJump.sizeof; 
                
                program ~= splitInstBuf;
                progLen -= InstSplit.sizeof;
            }

            if ( charRange.start == charRange.end )
            {
                byte[] buf;
                
                if ( reFlags.CaseInsensitive )
                {
                    mixin(MakeREInst( "InstIChar", "iCharInst" ));
                    iCharInst.c = charRange.start;
                    
                    buf = iCharInstBuf;
                }
                else
                {
                    mixin(MakeREInst( "InstChar", "charInst" ));
                    charInst.c = charRange.start;

                    buf = charInstBuf;
                }
                
                if ( !isLastRange ) // Adjust split
                {
                    InstSplit* splitInst = cast(InstSplit*)&program[$-InstSplit.sizeof];
                    splitInst.locSec += buf.length;
                }

                program ~= buf;
                progLen -= buf.length;
            }
            else
            {
                byte[] buf;

                if ( reFlags.CaseInsensitive )
                {
                    mixin( MakeREInst( "InstICharRange", "iCharRangeInst" ) );
                    iCharRangeInst.span.start = tolower(charRange.start);
                    iCharRangeInst.span.end = tolower(charRange.end);

                    buf = iCharRangeInstBuf;
                }
                else
                {
                    mixin( MakeREInst( "InstCharRange", "charRangeInst" ) );
                    charRangeInst.span = charRange;

                    buf = charRangeInstBuf;
                }

                if ( !isLastRange ) // Adjust split
                {
                    InstSplit* splitInst = cast(InstSplit*)&program[$-InstSplit.sizeof];
                    splitInst.locSec += buf.length;
                }

                program ~= buf;
                progLen -= buf.length;
            }

            if ( !isLastRange )
            {
                // Jump
                mixin( MakeREInst( "InstJump", "jumpInst" ) );
                jumpInst.loc = program.length + progLen;

                program ~= jumpInstBuf;
                progLen -= InstJump.sizeof;
            }
        }

        return end;
    }

    // Add ranges to ranges in a set
    void parseEscapedChar( dchar escChar, ref Span!dchar[] charRanges, RegexFlags reFlags )
    {
        switch( escChar )
        {
        case 'd':
            AddSpan( charRanges, Span!dchar( '0', '9' ) );
            break;
        case 'D':
            AddSpan( charRanges, Span!dchar( '0'-1, '9'+1 ) );
            break;
        case 's':
            AddSpan( charRanges, Span!dchar( '\t', '\t' ) );
            AddSpan( charRanges, Span!dchar( '\n', '\n' ) );
            AddSpan( charRanges, Span!dchar( '\f', '\f' ) );
            AddSpan( charRanges, Span!dchar( '\r', '\r' ) );
            break;
        case 'w':
            AddSpan( charRanges, Span!dchar( '0', '9' ) );
            AddSpan( charRanges, Span!dchar( 'A', 'Z' ) );
            AddSpan( charRanges, Span!dchar( 'a', 'z' ) );
            break;
        case 'W':
            AddSpan( charRanges, Span!dchar( '0'-1, '9'+1 ) );
            AddSpan( charRanges, Span!dchar( 'A'-1, 'Z'+1 ) );
            AddSpan( charRanges, Span!dchar( 'a'-1, 'z'+1 ) );
            break;
            
                
            // Single characters
        default:
            switch ( escChar )
            {
            case 'a':
                escChar = 007;
                break;
            case 'f':
                escChar = 014;
                break;
            case 't':
                escChar = 011;
                break;
            case 'n':
                escChar = 012;
                break;
            case 'r':
                escChar = 015;
                break;
            case 'v':
                escChar = 013;
                break;

            default:
                ; // escChar unmodified
            }

            if ( reFlags.CaseInsensitive )
            {
                AddSpan( charRanges, Span!dchar( tolower(escChar), tolower(escChar) ) );
                AddSpan( charRanges, Span!dchar( toupper(escChar), toupper(escChar) ) );
            }
            else
            {
                AddSpan( charRanges, Span!dchar( escChar, escChar ) );
            }
        }
    }

    void parseEscapedChar( dchar escChar, RegexFlags reFlags )
    {
        switch( escChar )
        {
        case 'd':
            parseSet( "[0-9]", reFlags );
            break;
        case 'D':
            parseSet( "[^0-9]", reFlags );
            break;
        case 's':
            parseSet( "[\t\n\f\r]", reFlags );
            break;
        case 'w':
            parseSet( "[0-9A-Za-z_]", reFlags );
            break;
        case 'W':
            parseSet( "[^0-9A-Za-z_]", reFlags );
            break;
        case 'b':
            mixin( MakeREInst( "InstWordBoundary", "wbInst" ) );
            program ~= wbInstBuf;
            break;
        case 'B':
            mixin( MakeREInst( "InstWordBoundary", "wbInst" ) );
            wbInst.positiveFlag = false;
            program ~= wbInstBuf;
            break;
            
                
            // Single characters
        default:
            fixedCharStack ~= 1;

            switch ( escChar )
            {
            case 'a':
                escChar = 007;
                break;
            case 'f':
                escChar = 014;
                break;
            case 't':
                escChar = 011;
                break;
            case 'n':
                escChar = 012;
                break;
            case 'r':
                escChar = 015;
                break;
            case 'v':
                escChar = 013;
                break;

            default:
                ; // escChar unmodified
            }

            if ( reFlags.CaseInsensitive )
            {
                mixin(MakeREInst( "InstIChar", "iCharInst" ));
                iCharInst.c = tolower(escChar);
                program ~= iCharInstBuf;
            }
            else
            {
                mixin(MakeREInst( "InstChar", "charInst" ));
                charInst.c = escChar;
                program ~= charInstBuf;
            }
        }
    }

    size_t parseAtom(String)( String s, ref RegexFlags reFlags )
    {
        size_t start = 0;
        size_t end=0;
        if ( s.length == 0 )
        {
            writefln( "parseAtom error" );
        }

        size_t startPos = start;
        dchar c = decode( s, startPos );

        if ( c == '(' ) // a group
        {
            end = parseGroup( s, reFlags );
        }
        else if ( c == '[' ) // a set
        {
            end = parseSet( s, reFlags );
        }
        else if ( c == '.' )
        {
            fixedCharStack ~= 1;

            decode( s, end );

            mixin( MakeREInst( "InstAnyChar", "anyCharInst" ) );
            program ~= anyCharInstBuf;
        }
        else if ( c == '\\' ) // escaped character
        {
            fixedCharStack ~= 1;

            if ( s.length == 1 )
                writefln( "parseAtom error escape character" );
            decode( s, end ); // Advances end

            dchar escChar = decode( s, end );
            parseEscapedChar( escChar, reFlags );
        }
        else if ( c == '^' ) // BOL or BOT
        {
            decode( s, end );

            if ( reFlags.MultiLine )
            {
                mixin( MakeREInst( "InstBOL", "bolInst" ) );
                program ~= bolInstBuf;
            }
            else
            {
                mixin( MakeREInst( "InstBOT", "botInst" ) );
                program ~= botInstBuf;
            }
        }
        else if ( c == '$' )
        {
            decode( s, end );

            if ( reFlags.MultiLine )
            {
                mixin( MakeREInst( "InstEOL", "eolInst" ) );
                program ~= eolInstBuf;
            }
            else
            {
                mixin( MakeREInst( "InstEOT", "eotInst" ) );
                program ~= eotInstBuf;
            }
        }
        else // Character
        {
            fixedCharStack ~= 1;

            if ( reFlags.CaseInsensitive )
            {
                mixin( MakeREInst( "InstIChar", "iCharInst" ) );
                iCharInst.c = tolower(decode( s, end )); // Advances end
                program ~= iCharInstBuf;
            }
            else
            {
                mixin( MakeREInst( "InstChar", "charInst" ) );
                charInst.c = decode( s, end ); // Advances end
                program ~= charInstBuf;
            }
        }

        return end;
    }
}

BackTrackEngine btregex(String)( String s )
{
    // Cache last request (this technique is from std.regex)
    static String lastReq;
    static typeof(return) lastResult;
    if ( lastReq == s )
        return lastResult;

    auto re = new Regex(s);
    auto result = new BackTrackEngine( re );

    lastReq = cast(String) s.dup;
    lastResult = result;

    return result;
}

LockStepEngine lsregex(String)( String s )
{
    // Cache last request (this technique is from std.regex)
    static String lastReq;
    static typeof(return) lastResult;
    if ( lastReq == s )
        return lastResult;

    auto re = new Regex(s);
    auto result = new LockStepEngine( re );

    lastReq = cast(String) s.dup;
    lastResult = result;

    return result;
}


// TODO: Add range interface to match and captures like std.regex

// Match could be parameterized on the number of captures if it were
// known at compile time to avoid dynamic allocation.
// If the user knows, or knows a maximum number of captures, it can be
// passed as a template parameter to the regex engine match function,
// which can use the available space.
public struct Match(String,int NumCaptures)
{
    private String _captureString;
    private size_t _captures[2*NumCaptures] = size_t.max;

    public void setNumCaptures( int numCaptures )
    {
        assert( 2*numCaptures <= _captures.length );
    }

    bool opCast(T)() if (is(T == bool))
    {
        return _captures[0] != size_t.max;
    }

    String opIndex( uint i )
    {
        return _captureString[ _captures[2*i].._captures[2*i+1] ];
    }

    @property const size_t length()
    {
        return _captures.length / 2;
    }

    @property const size_t startMatch()
    {
        if ( _captures.empty )
            throw new Exception( "Match has not matched a string" );

        return _captures[0];
    }

    @property const size_t endMatch()
    {
        if ( _captures.empty )
            throw new Exception( "Match has not matched a string" );

        return _captures[1];
    }
}

public struct Match(String)
{
    public void setNumCaptures( int numCaptures )
    {
        _numCaptures = numCaptures;
        _captures.length = numCaptures * 2;
    }

    private size_t _numCaptures;
    private String _captureString;
    private size_t _captures[];

    bool opCast(T)() if (is(T == bool))
    {
        return _captures.length > 0 &&_captures[0] != size_t.max;
    }

    String opIndex( uint i )
    {
        return _captureString[ _captures[2*i].._captures[2*i+1] ];
    }

    @property size_t length()
    {
        return _captures.length / 2;
    }

    @property size_t startMatch()
    {
        if ( _captures.empty )
            throw new Exception( "Match has not matched a string" );

        return _captures[0];
    }

    @property size_t endMatch()
    {
        if ( _captures.empty )
            throw new Exception( "Match has not matched a string" );

        return _captures[1];
    }
}

public MatchRange!(String,Regex,Match!String) match(String,Regex)( String s, Regex re )
{
    return MatchRange!(String,Regex,Match!String)( s, re );
}

// Match with static match object, avoiding dynamic allocations for captures
public MatchRange!(String,Regex,Match!(String,NumCaptures))
staticMatch( int NumCaptures, String, Regex )( String s, Regex re )
{
    return MatchRange!(String,Regex,Match!(String,NumCaptures))( s, re );
}

// Match with range primitives ala std.regex
public struct MatchRange(String,RegexEngine,MatchType)
{
    private MatchType _match;
    private RegexEngine _re;
    private String _matchString;

    this( String s, RegexEngine re )
    {
        _matchString = s;
        _re = re;
        //_match._captures.length = 2*_re._numCaptures;

        _re.matchAt( _matchString, _match, 0 );
    }

    bool opCast(T)() if (is(T == bool))
    {
        return !empty;
    }

    @property bool empty()
    {
        return _match._captures.length == 0 ||
            _match._captures[0] == size_t.max;
    }

    void popFront()
    {
        size_t sPos = _match._captures[1];
        // if the match length is 0, move to the next character
        if ( _match._captures[1]-_match._captures[0] == 0 )
        {
            decode( _matchString, sPos );
        }

        _re.matchAt( _matchString, _match, sPos );
    }

    MatchRange!(String,RegexEngine,MatchType) front()
    {
        return this;
    }

    String pre()
    {
        return _matchString[0.._match._captures[0]];
    }

    String hit()
    {
        return _matchString[_match._captures[0].._match._captures[1]];
    }

    String post()
    {
        return _matchString[_match._captures[1]..$];
    }
    
    @property Captures!(String,MatchType) captures()
    {
        return Captures!(String,MatchType)(_match);
    }
}

// Range interface for match captures
public struct Captures(String,MatchType)
{
    private MatchType _match;
    int _captureNum=0;

    this( MatchType match )
    {
        _match = match;
    }

    String opIndex( uint i )
    {
        return _match[i];
    }

    @property bool empty()
    {
        if ( _captureNum >= _match.length ||
             _match._captures[_captureNum] == size_t.max )
            return true;
        else
            return false;
    }

    @property void popFront()
    {
        assert(!empty);
        ++_captureNum;
    }

    @property String front()
    {
        return _match[_captureNum];
    }

    @property size_t length()
    {
        return _match.length;
    }
}

unittest
{
    foreach( m; match( "aaa", btregex( "." ) ) )
    {
        writefln( "match = %s[%s]%s", m.pre(), m.hit(), m.post() );
    }

    foreach( m; match( "aaa", lsregex( "." ) ) )
    {
        writefln( "match = %s[%s]%s", m.pre(), m.hit(), m.post() );
    }

    foreach( m; match( "She sells sea shells on the sea shore"d, btregex( `\b(?i)s\w+` ) ) )
    {
        writefln( "match = %s[%s]%s", m.pre(), m.hit(), m.post() );
    }

    foreach( c; match( "user@domain.com",
                       btregex(r"([a-zA-Z0-9._%+-]+)@([a-zA-Z0-9.-]+\.[a-zA-Z]{2,4})" ) ).captures )
    {
        writefln( "capture = %s", c );
    }
}

// must decode backwards by distance chars if possible
// utf8
private bool rDecode( in char[] s, ref size_t idx )
{
    
    // scan backwards for a lead byte (not 10...)
    size_t tidx = idx;
    do
    {
        if ( tidx == 0 )
            return false;
        --tidx;
    } while( (s[tidx] & 0xc0) == 0x80 );
    
    idx = tidx;
    return true;
}

// utf32
private bool rDecode( in dchar[] s, ref size_t idx )
{
    if ( idx == 0 )
        return false;
    else
    {
        --idx;
        return true;
    }
}

// utf16
private bool rDecode( in wchar[] s, ref size_t idx )
{
    if ( idx == 0 )
        return false;
    else
    {
        --idx;
        // check for high surrogate
        if ( s[idx] >= 0xd800 && s[idx] <= 0xdbff )
            --idx;
        return true;
    }
}


public class BackTrackEngine
{
    private Regex _re;
    private size_t _numStates;
    private size_t _numCaptures;
    private size_t[] _captures;

    this( Regex re )
    {
        _re = re;
        _numStates = re.numStates;
        _numCaptures = re.numCaptures;
        _captures.length = re.numCaptures*2;
    }

    int execute(String)( size_t pc, size_t sPos, size_t prevSPos, String s )
    {
        auto program = _re.program;

        for( ;; )
        {
            Inst* inst = cast(Inst*)&program[pc];

            final switch( inst.type )
            {
            case REInst.Char:
                if ( sPos == s.length )
                    return 0;
                // get next character and advance sPos
                prevSPos = sPos;
                dchar thisChar = decode( s, sPos );
                auto instChar = cast(InstChar*)inst;
                if ( instChar.c != thisChar )
                    return 0;

                pc += InstChar.sizeof;
                break;

            case REInst.IChar:
                if ( sPos == s.length )
                    return 0;
                // get next character and advance sPos
                prevSPos = sPos;
                dchar thisChar = decode( s, sPos );
                auto instIChar = cast(InstIChar*)inst;
                if ( instIChar.c != tolower(thisChar) )
                    return 0;

                pc += InstIChar.sizeof;

                break;

            case REInst.AnyChar:
                if ( sPos == s.length )
                    return 0;
                // get next character and advance sPos
                prevSPos = sPos;
                dchar thisChar = decode( s, sPos );
                pc += InstAnyChar.sizeof;

                break;

            case REInst.CharRange:
                auto instCharRange = cast(InstCharRange*)inst;
                if ( sPos == s.length )
                    return 0;
                // get next character and advance sPos
                prevSPos = sPos;
                dchar thisChar = decode( s, sPos );

                if ( ! ( thisChar >= instCharRange.span.start &&
                         thisChar <= instCharRange.span.end )  )
                    return 0;

                pc += InstCharRange.sizeof;

                break;

            case REInst.ICharRange:
                auto instICharRange = cast(InstICharRange*)inst;
                if ( sPos == s.length )
                    return 0;
                // get next character and advance sPos
                prevSPos = sPos;
                dchar thisChar = tolower( decode( s, sPos ) );

                if ( ! ( thisChar >= instICharRange.span.start &&
                         thisChar <= instICharRange.span.end )  )
                    return 0;

                pc += InstICharRange.sizeof;

                break;

            case REInst.CharBitmap:
                auto instCharBitmap = cast(InstCharBitmap*)inst;
                if ( sPos == s.length )
                    return 0;
                // get next character and advance sPos
                prevSPos = sPos;
                dchar thisChar = decode( s, sPos );

                if ( !(*instCharBitmap)[thisChar] )
                    return 0;
                    
                pc += InstCharBitmap.sizeof;

                break;

            case REInst.Save:
                auto instSave = cast(InstSave*)inst;
                    
                size_t oldCapture = _captures[instSave.num];
                _captures[instSave.num] = sPos;

                pc += InstSave.sizeof;
                if ( execute( pc, sPos, prevSPos, s ) )
                    return 1;

                // Restore old capture if thread has failed
                _captures[instSave.num] = oldCapture;
                return 0;

                break;

            case REInst.Split:
                auto instSplit = cast(InstSplit*)inst;
                if ( execute( instSplit.locPref, sPos, prevSPos, s ) )
                    return 1;
                pc = instSplit.locSec;

                break;

            case REInst.Jump:
                auto instJump = cast(InstJump*)inst;
                pc = instJump.loc;

                break;

            case REInst.Match:
                return 1;

            case REInst.BOL:
                if ( !isNewLineChar( s, prevSPos ) )
                    return 0;

                pc += InstBOL.sizeof;
                break;

            case REInst.EOL:
                if ( !isNewLineChar( s, sPos ) )
                    return 0;

                pc += InstEOL.sizeof;
                break;

            case REInst.BOT:
                if ( sPos != 0 )
                    return 0;

                pc += InstBOL.sizeof;
                break;

            case REInst.EOT:
                if ( sPos != s.length )
                    return 0;

                pc += InstEOL.sizeof;
                break;

            case REInst.WordBoundary:
                bool result=false;
                        
                if( isWordChar( s, prevSPos ) &&
                    !isWordChar( s, sPos ) )
                    result = true;
                else if ( !isWordChar( s, prevSPos ) &&
                          isWordChar( s, sPos ) )
                    result = true;

                auto instWordBoundary = cast(InstWordBoundary*)inst;

                if ( result != instWordBoundary.positiveFlag )
                    return 0;

                pc += InstWordBoundary.sizeof;
                break;

            case REInst.LookAround:
                pc += InstLookAround.sizeof;
                auto instLookAround = cast(InstLookAround*)inst;
                
                if ( instLookAround.ahead )
                {
                    if ( execute( pc, sPos, prevSPos, s ) != instLookAround.positive )
                        return 0;

                    pc = instLookAround.jumpLoc;
                }
                else
                {

                    size_t shiftedSPos = sPos;
                    size_t shiftedPrevSPos;

                    for( int i=0; i<instLookAround.distance; ++i )
                    {
                        if( !rDecode( s, shiftedSPos ) )
                            return false;
                    }
                    if ( shiftedSPos == 0 )
                        shiftedPrevSPos = size_t.max;
                    else
                        shiftedPrevSPos = shiftedSPos - 1;
                    
                    if ( execute( pc, shiftedSPos, shiftedPrevSPos, s ) != instLookAround.positive )
                        return 0;
                    pc = instLookAround.jumpLoc;
                }

                break;
            }
        }

        return 0;
    }

    Match!String matchAt(String)( String s, size_t startPos=0 )
    {
        Match!String matchData;
        matchAt( s, matchData, startPos );

        return matchData;
    }

    void matchAt(String,MatchType)( String s, ref MatchType match, size_t startPos=0 )
    {
        auto program = _re.program;

        // Write captures directly into match
        // Perhaps captures should be an argument instead of a member
        //match._captures.length = 2*_numCaptures;
        match.setNumCaptures( _numCaptures );
        _captures = match._captures;

        _captures[] = size_t.max;

        if( execute( 0, startPos, size_t.max, s ) )
        {
            match._captureString = s;
        }
        else
        {
            match._captureString = "";
        }
    }

    void printProgram()
    {
        .printProgram( _re.program );
    }
}


public class LockStepEngine
{
    private Threads _currentThreads;
    private Threads _consumingThreads;
    private Threads _executingThreads;
    private size_t _stringPosition;
    private size_t _currentGeneration;
    private size_t _prevGeneration; // used for decoding previous character for word boundary
    //private size_t[] _emptyCaptures;
    private size_t[] _stateGenerations;
    private Regex _re;

    private size_t _numStates;
    private size_t _numCaptures;

    this( Regex re )
    {
        _re = re;

        _numStates = re.numStates;
        _numCaptures = re.numCaptures;

        //_emptyCaptures.length = _numCaptures*2;
        _currentThreads = new Threads( _numStates, _numCaptures );
        _consumingThreads = new Threads( _numStates, _numCaptures );
        _executingThreads = new Threads( _numStates, _numCaptures );
        _stateGenerations.length = _numStates;
    }

    void getConsumingThreads(String)( ref String s, ref size_t[] captures )
    {
        byte[] program = _re.program;

        // executing can be stored at the top of consumingthreads, but
        // keep it simple for now
        _consumingThreads.clear();
        _executingThreads.clear();

        for( size_t threadsIdx = 0; threadsIdx < _currentThreads.length; ++threadsIdx )
        {
            _executingThreads.push( _currentThreads.pcAtIndex( threadsIdx ),
                                   _currentThreads.capturesAtIndex( threadsIdx ) );

            // execute threads, pushing consuming threads onto
            // consumingThreads, until executingThreads is empty
            while( _executingThreads.length > 0 )
            {
                size_t pc = _executingThreads.pc;
                
                Inst* inst = cast(Inst*)&program[pc];
                if ( _stateGenerations[inst.stateNumber] != _currentGeneration )
                {
                    _stateGenerations[inst.stateNumber] = _currentGeneration;
                    final switch( inst.type )
                    {
                        // Consuming instructions are added to consumingThreads
                    case REInst.Char:
                    case REInst.IChar:
                    case REInst.AnyChar:
                    case REInst.CharRange:
                    case REInst.ICharRange:
                    case REInst.CharBitmap:
                        _consumingThreads.push( pc, _executingThreads.captures );
                        break;

                    case REInst.Save:
                        InstSave* instSave = cast(InstSave*)inst;

                        // increment pc
                        _executingThreads.pc = pc + InstSave.sizeof;
                        // set capture
                        _executingThreads.captures[instSave.num] = _currentGeneration;
                        break;

                    case REInst.Split:
                        InstSplit* instSplit = cast(InstSplit*)inst;
                        // Set pc for secondary (captures unchanged)
                        _executingThreads.pc = instSplit.locSec;
                        // Push primary onto top
                        _executingThreads.push( instSplit.locPref, _executingThreads.captures );

                        break;

                    case REInst.Jump:
                        InstJump* instJump = cast(InstJump*)inst;
                        // Update pc to jump target
                        _executingThreads.pc = instJump.loc;
                        break;

                    case REInst.Match:  // Doesn't consume anything
                        // TODO: decide the best thing to do here
                        captures[] = _executingThreads.captures[]; // copy captures
                        return; // we're done for this length, but we
                                // can keep going to match longer
                                // strings if there are any consuming
                                // threads left
                        break;

                    case REInst.BOL:
                        if ( isNewLineChar( s, _prevGeneration ) )
                            _executingThreads.pc = pc + InstBOL.sizeof;
                        else
                            _executingThreads.pop();
                        break;

                    case REInst.EOL:
                        if ( isNewLineChar( s, _currentGeneration ) )
                            _executingThreads.pc = pc + InstEOL.sizeof;
                        else
                            _executingThreads.pop();
                        break;

                    case REInst.BOT:
                        // If at beginning of string, increment pc, otherwise pop instruction
                        if ( _currentGeneration == 0 )
                            _executingThreads.pc = pc + InstBOL.sizeof;
                        else
                            _executingThreads.pop();
                        break;

                    case REInst.EOT:
                        if ( _currentGeneration == s.length )
                            _executingThreads.pc = pc + InstEOL.sizeof;
                        else
                            _executingThreads.pop();
                        break;

                    case REInst.WordBoundary:
                        bool result=false;

                        if( isWordChar( s, _prevGeneration ) &&
                            !isWordChar( s, _currentGeneration ) )
                            result = true;
                        else if ( !isWordChar( s, _prevGeneration ) &&
                                  isWordChar( s, _currentGeneration ) )
                            result = true;

                        auto instWordBoundary = cast(InstWordBoundary*)inst;
                        
                        if ( result == instWordBoundary.positiveFlag )
                            _executingThreads.pc = pc + InstWordBoundary.sizeof;
                        else
                            _executingThreads.pop();

                        break;

                    case REInst.LookAround:
                        throw new Exception( "LookAround not supported by lockstep engine" );
                    }
                }
                else // Pop instruction we've already done
                {
                    _executingThreads.pop();
                }
            }
        }
    }

    /*
      - Get consuming threads
      - if there are any threads left, read a character
      - execute 1 step of consuming threads, push surviving threads onto current threads
      - repeat
      - we'll know if we matched something if captures isn't empty
     */

    Match!String matchAt(String)( String s, size_t startPos=0 )
    {
        Match!String matchData;
        matchAt( s, matchData, startPos );

        return matchData;
    }
    
    void matchAt(String,MatchType)( String s, ref MatchType match, size_t startPos=0 )
    {
        _stateGenerations[] = size_t.max;
        //_emptyCaptures[] = size_t.max;
        _prevGeneration=size_t.max;
        _currentGeneration=0;
        _stringPosition=0;
        _currentThreads.clear();
        
        auto program = _re.program;

        //size_t[] captures = _emptyCaptures.dup;
        match._captures.length = 2*_numCaptures;
        size_t[] captures = match._captures;
        match._captureString = s;
        captures[] = size_t.max; // mark unmatched

        _currentThreads.push( 0, captures );

        getConsumingThreads( s, captures );

        dchar prevChar;

        size_t nextCharIdx = startPos;
        while( _consumingThreads.length > 0 && nextCharIdx < s.length )
        {
            _currentThreads.clear();
            
            dchar thisChar = decode( s, nextCharIdx );
            _prevGeneration = _currentGeneration;
            _currentGeneration = nextCharIdx;


            // Execute consumingThreads 1 step, and push survivors onto _currentThreads
            for( size_t threadsIdx = 0; threadsIdx < _consumingThreads.length; ++threadsIdx )
            {
                size_t pc = _consumingThreads.pcAtIndex( threadsIdx );
                Inst* inst = cast(Inst*)&program[pc];

                static string pushNextInst( string instType )
                {
                    string result =
                        "_currentThreads.push( pc + "~instType~".sizeof,
                                              _consumingThreads.capturesAtIndex( threadsIdx ) );";
                    return result;
                }
                
                final switch( inst.type )
                {
                    // Consuming instructions are added to consumingThreads
                case REInst.Char:
                    auto instChar = cast(InstChar*)inst;
                    if ( instChar.c == thisChar )
                        mixin( pushNextInst( "InstChar" ) );
                    break;
                case REInst.IChar:
                    auto instIChar = cast(InstIChar*)inst;
                    if ( instIChar.c == tolower( thisChar ) )
                        mixin( pushNextInst( "InstIChar" ) );
                    break;
                case REInst.AnyChar:
                        mixin( pushNextInst( "InstAnyChar" ) );
                    break;
                case REInst.CharRange:
                    auto instCharRange = cast(InstCharRange*)inst;
                    if ( thisChar >= instCharRange.span.start &&
                         thisChar <= instCharRange.span.end )
                        mixin( pushNextInst( "InstCharRange" ) );
                    break;
                case REInst.ICharRange:
                    auto instICharRange = cast(InstICharRange*)inst;
                    dchar lowChar = tolower( thisChar );
                    if ( lowChar >= instICharRange.span.start &&
                         lowChar <= instICharRange.span.end )
                        mixin( pushNextInst( "InstICharRange" ) );
                    break;
                case REInst.CharBitmap:
                    auto instCharBitmap = cast(InstCharBitmap*)inst;
                    if ( (*instCharBitmap)[thisChar] )
                        mixin( pushNextInst( "InstCharBitmap" ) );
                    break;

                case REInst.Save:
                case REInst.Split:
                case REInst.Jump:
                case REInst.BOL:
                case REInst.EOL:
                case REInst.BOT:
                case REInst.EOT:
                case REInst.Match:
                case REInst.WordBoundary:
                    throw new Exception( "Unexpected instruction" );
                case REInst.LookAround:
                    throw new Exception( "LookAround not supported by lockstep engine" );
                }
            }
            
            // Get consuming threads for next rount
            getConsumingThreads( s, captures );
        }
 
        // Final getConsumingThreads so matches are executed after final character
        getConsumingThreads( s, captures );
        
        /*
        //Match!String matchData;
        if ( captures[0] != size_t.max ) // If we assigned something to captures, we must have had a match
        {
            matchData = Match!String( captures, s );
        }
        else
        {
            captures.length = 0;
            matchData = Match!String( captures, "" );
        }
                                      
        return matchData;
        */
    }

    void printProgram()
    {
        .printProgram( _re.program );
    }

    private class Threads
    {
        this( int maxThreads, int numCaptures )
        {
            _numThreads = maxThreads;
            _threadSize = size_t.sizeof * (2*numCaptures+1);
            _data.length = _numThreads * _threadSize;
        }

        @property size_t pc()
        {
            //return pcAtIndex( _stackPos-1 );
            size_t offset = (_stackPos-1) * _threadSize;
            return *cast(size_t*)&_data[offset];
        }

        @property void pc( size_t pc )
        {
            //setPcAtIndex( _stackPos-1, pc );
            size_t offset = (_stackPos-1) * _threadSize;
            *cast(size_t*)&_data[offset] = pc;
        }

        @property size_t[] captures()
        {
            //return capturesAtIndex( _stackPos-1 );
            size_t offset = (_stackPos-1) * _threadSize;
            return cast(size_t[])_data[offset+size_t.sizeof..offset+_threadSize];
        }

        @property void captures( size_t[] captures )
        {
            //setCapturesAtIndex( _stackPos-1, captures );
            size_t offset = (_stackPos-1) * _threadSize;
            size_t[] target = cast(size_t[])_data[offset+size_t.sizeof..offset+_threadSize];
            if ( target !is captures )
                target[] = captures[];
        }

        size_t pcAtIndex( size_t index )
        {
            size_t offset = index * _threadSize;
            return *cast(size_t*)&_data[offset];
        }

        void setPcAtIndex( size_t index, size_t pc )
        {
            size_t offset = index * _threadSize;
            *cast(size_t*)&_data[offset] = pc;
        }

        size_t[] capturesAtIndex( size_t index )
        {
            size_t offset = index * _threadSize;
            return cast(size_t[])_data[offset+size_t.sizeof..offset+_threadSize];
        }

        void setCapturesAtIndex( size_t index, size_t[] captures )
        {
            size_t offset = index * _threadSize;
            size_t[] target = cast(size_t[])_data[offset+size_t.sizeof..offset+_threadSize];
            if ( target !is captures )
                target[] = captures[];
        }

        void setAtIndex( size_t index, size_t pc, size_t[] captures )
        {
            size_t offset = index * _threadSize;
            *cast(size_t*)&_data[offset] = pc;
            size_t[] target = cast(size_t[])_data[offset+size_t.sizeof..offset+_threadSize];
            if ( target !is captures ) // equal bounds
                target[] = captures[];
        }

        void push( size_t pc, size_t captures[] )
        {
            if ( _stackPos >= _numThreads )
                throw new Exception( "Threads.push stack overflow" );

            //setAtIndex( _stackPos, pc, captures );
            size_t offset = _stackPos * _threadSize;
            *cast(size_t*)&_data[offset] = pc;
            size_t[] target = cast(size_t[])_data[offset+size_t.sizeof..offset+_threadSize];
            if ( target !is captures ) // equal bounds
                target[] = captures[];
            ++_stackPos;
        }
        
        void pop()
        {
            if ( _stackPos <=0 )
                throw new Exception( "Threads.pop stack underflow" );
            --_stackPos;
        }

        void clear()
        {
            _stackPos = 0;
        }

        @property size_t length()
        {
            return _stackPos;
        }

        private size_t _numThreads;
        private size_t _threadSize;
        private byte[] _data;
        private size_t _stackPos;
    }

}

public class Regex
{
    byte[] program;
    size_t numStates;
    size_t numCaptures;

    // No template constructors for classes
    // wstring or dstring constructor results in argument matching error
    this()
    {

    }

    this( string s )
    {
        initialize( s );
    }

    this( wstring s )
    {
        initialize( s );
    }

    this( dstring s )
    {
        initialize( s );
    }

    static Regex opCall(String)( String s )
    {
        Regex re = new Regex();
        re.initialize( s );

        return re;
    }
    
    void initialize(String)(String s, string attributes = null )
    {
        RegexParser.RegexFlags reFlags;
        auto parser = RegexParser( s, reFlags );
        program = parser.program;
        numCaptures = parser.numCaptures;
        enumerateStates( program, numStates );
    }

    void printProgram()
    {
        writefln( "Hello" );
        .printProgram( program );
    }

}




unittest
{
    auto re = Regex( r".*" );
    auto eng = new LockStepEngine( re );
    assert( eng.matchAt( "a" ) );
    auto bteng = new BackTrackEngine( re );
    assert( bteng.matchAt( "a" ) );
}

unittest
{
    auto re = lsregex( r".*" );
    auto btre = btregex( r".*" );
    auto m = re.matchAt( "a" );

    //assert( match( "" , lsregex( r"a*" ) ) );
    assert( match( "" , btregex( r"a*" ) ) );
    assert( !lsregex( r"a+" ).matchAt( "" ) );
    assert( !btregex( r"a+" ).matchAt( "" ) );
    assert( lsregex( r"a+" ).matchAt( "a" ) );
    assert( btregex( r"a+" ).matchAt( "a" ) );
    assert( lsregex( "a?" ).matchAt( "" ) );
    assert( btregex( "a?" ).matchAt( "" ) );
    assert( lsregex( "a?" ).matchAt( "a" ) );
    assert( btregex( "a?" ).matchAt( "a" ) );
    assert( !lsregex( "a{2,3}" ).matchAt( "a" ) );
    assert( !btregex( "a{2,3}" ).matchAt( "a" ) );
    assert( lsregex( "a{2,3}" ).matchAt( "aa" ) );
    assert( btregex( "a{2,3}" ).matchAt( "aa" ) );
    assert( lsregex( "a{2,3}b" ).matchAt( "aaab" ) );
    assert( btregex( "a{2,3}b" ).matchAt( "aaab" ) );
    assert( !lsregex( "^a{2,3}b" ).matchAt( "aaaab" ) );
    assert( !btregex( "^a{2,3}b" ).matchAt( "aaaab" ) );
    assert( lsregex( "(123)?" ).matchAt( "123" ) );
    assert( btregex( "(123)?" ).matchAt( "123" ) );
    assert( lsregex( "[A-Z]?x" ).matchAt( "Bx" ) );
    assert( btregex( "[A-Z]?x" ).matchAt( "Bx" ) );
    assert( lsregex( "[A-Z0-9]+x" ).matchAt( "3x" ) );
    assert( btregex( "[A-Z0-9]+x" ).matchAt( "3x" ) );
    assert( !lsregex( "[A-Z0-9]+x" ).matchAt( "x" ) );
    assert( !btregex( "[A-Z0-9]+x" ).matchAt( "x" ) );
    assert( lsregex( "ab" ).matchAt( "abcdef" ).endMatch == 2 );
    assert( btregex( "ab" ).matchAt( "abcdef" ).endMatch == 2 );
    assert( !lsregex( "ab$" ).matchAt( "abcdef" ) );
    assert( !btregex( "ab$" ).matchAt( "abcdef" ) );
    assert( lsregex( "ab$" ).matchAt( "leadingstuffab" ) );
    assert( btregex( "ab$" ).matchAt( "leadingstuffab" ) );
    assert( !lsregex( "^ab$" ).matchAt( "leadingstuffab" ) );
    assert( !btregex( "^ab$" ).matchAt( "leadingstuffab" ) );
    assert( lsregex( r"^\bZ\b \bY\BX\b \bW\BV\BU\b$" ).matchAt( "Z YX WVU" ) );
    assert( btregex( r"^\bZ\b \bY\BX\b \bW\BV\BU\b$" ).matchAt( "Z YX WVU" ) );
    assert( !lsregex( r"^X\bY$" ).matchAt( "XY" ) );
    assert( !btregex( r"^X\bY$" ).matchAt( "XY" ) );

    // browsing bugzilla for dmd regex issues
    // 5511
    m = lsregex( "(a(.*))?(b)" ).matchAt( "ab" );
    assert(m.length == 4);
    assert(m[0] == "ab");
    assert(m[1] == "a");
    assert(m[2] == "");
    assert(m[3] == "b");
    m = lsregex( "(a(.*))?(b)" ).matchAt( "b" );
    assert(m.length == 4);
    assert(m[0] == "b");
    assert(m[1] == "");
    assert(m[2] == "");
    assert(m[3] == "b");

    // 2108
    assert( lsregex( "<packet.*/packet>" ).matchAt( "<packet>text</packet><packet>text</packet>" )[0] ==
            "<packet>text</packet><packet>text</packet>" );
    assert( btregex( "<packet.*/packet>" ).matchAt( "<packet>text</packet><packet>text</packet>" )[0] ==
            "<packet>text</packet><packet>text</packet>" );


    // 5019
    assert( lsregex("abc(.*)").matchAt( "abc" )[1] == "" );
    assert( btregex("abc(.*)").matchAt( "abc" )[1] == "" );
    // 5523
    assert( lsregex( `([\s_]|sec)` ).matchAt( "sec" )[0] == "sec" );

    enum string email =
        r"([a-zA-Z0-9._%+-]+)@([a-zA-Z0-9.-]+\.[a-zA-Z]{2,4})";

    assert( lsregex( email ).matchAt( "user@domain.name.com" ) );
    assert( !lsregex( email ).matchAt( "not.an.email.address" ) );
   
    m = lsregex( email ).matchAt( "User@domain.name.com" );
    assert( m[1] == "User" );
    assert( m[2] == "domain.name.com" );

    m = btregex( email ).matchAt( "User@domain.name.com" );
    assert( m[1] == "User" );
    assert( m[2] == "domain.name.com" );

    re = lsregex( "(?:(?i)[ab]b)(?:.)b[ab]" );
    assert( re.matchAt( "ABoba" ).length == 1 );

    btre = btregex( "(?:(?i)[ab]b)(?:.)b[ab]" );
    assert( btre.matchAt( "ABoba" ).length == 1 );

    assert( lsregex( "<.*>" ).matchAt( "<one><two><three>" )[0] == "<one><two><three>" );
    assert( btregex( "<.*>" ).matchAt( "<one><two><three>" )[0] == "<one><two><three>" );
    assert( lsregex( "<.*?>" ).matchAt( "<one><two><three>" )[0] == "<one>" );
    assert( btregex( "<.*?>" ).matchAt( "<one><two><three>" )[0] == "<one>" );

    // Multi line mode
    assert( lsregex( "(?m)^yum$" ).matchAt( "yuck\nyum\nyuck" ) );
    assert( btregex( "(?m)^yum$" ).matchAt( "yuck\nyum\nyuck" ) );
    assert( !lsregex( "^yum$" ).matchAt( "yuck\nyum\nyuck" ) );
    assert( !btregex( "^yum$" ).matchAt( "yuck\nyum\nyuck" ) );

    Match!(string,2) staticm;
    btregex( ".*(yum).*" ).matchAt( "yuckyumyuck", staticm );

    assert( staticm );
    assert( staticm[0] == "yuckyumyuck" );
    assert( staticm[1] == "yum" );

    // Non ascii characters
    assert( lsregex( "こ(.*)" ).matchAt( "こんにちは" )[1] == "んにちは" );
    assert( btregex( "こ(.*)" ).matchAt( "こんにちは" )[1] == "んにちは" );
    assert( lsregex( "[こん]*" ).matchAt( "こんにちは" )[0] == "こん" );
    assert( btregex( "[こん]*" ).matchAt( "こんにちは" )[0] == "こん" );
    assert( lsregex( "[^こん]*$" ).matchAt( "こんにちは" )[0] == "にちは" );
    assert( btregex( "[^こん]*$" ).matchAt( "こんにちは" )[0] == "にちは" );

    // Lookahead tests (only for backtracking engine)
    assert( btregex( "q(?=u)" ).matchAt( "qu" )[0] == "q" );
    assert( !btregex( "q(?=u)" ).matchAt( "qo" ) );
    assert( !btregex( "q(?!u)" ).matchAt( "qu" ) );
    assert( btregex( "q(?!u)" ).matchAt( "qこ" )[0] == "q" );

    // Lookbehind tests
    assert( btregex( "(?<=q)u" ).matchAt( "qu" )[0] == "u" );
    assert( !btregex( "(?<=q)u" ).matchAt( "nu" ) );
    assert( !btregex( "(?<!q)u" ).matchAt( "qu" ) );
    assert( btregex( "(?<!q)ん" ).matchAt( "こん" )[0] == "ん" );

    // char, wchar, dchar combinations (include surrogate pair character '𪛖')
    // http://zsigri.tripod.com/fontboard/cjk/surrog.html

    assert( match( "こんにちは 𪛖", btregex( "こんにちは 𪛖" ) ) );
    assert( match( "こんにちは 𪛖", btregex( "こんにちは 𪛖"w ) ) );
    assert( match( "こんにちは 𪛖", btregex( "こんにちは 𪛖"d ) ) );
    assert( match( "こんにちは 𪛖"w, btregex( "こんにちは 𪛖" ) ) );
    assert( match( "こんにちは 𪛖"w, btregex( "こんにちは 𪛖"w ) ) );
    assert( match( "こんにちは 𪛖"w, btregex( "こんにちは 𪛖"d ) ) );
    assert( match( "こんにちは 𪛖"d, btregex( "こんにちは 𪛖" ) ) );
    assert( match( "こんにちは 𪛖"d, btregex( "こんにちは 𪛖"w ) ) );
    assert( match( "こんにちは 𪛖"d, btregex( "こんにちは 𪛖"d ) ) );

    // Static match
    assert( staticMatch!1( "こんにちは 𪛖"d, btregex( "こんにちは 𪛖"d ) ) );
}
