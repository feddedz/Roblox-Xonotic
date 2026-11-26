// tokenizer quirks (COM_ParseToken_QuakeC); not the first file, so a "}" ending a general parameter line is swallowed
// (textures/tv/crlf below has CRLF line ends, textures/tv/cr lone CR line ends)

// an empty name again: bucket 191 now has textures/tv/chainhead211 at its head, so this one is chained
""
{
	surfaceparm nodraw
	{
		map textures/tv/empty.tga
	}
}

// and a third one is a redeclaration of the chained one
""
{
	surfaceparm water
}

"textures/tv/quoted name"
{
	surfaceparm "nodraw"
	{
		"map" "textures/tv/quoted file.tga"
	}
}

'textures/tv/single "dq" inside'
{
	surfaceparm 'water'
}

"textures/tv/esc\tname\\x\"q"
{
	sky "env/esc\nsky"
}

textures/tv/comments // a comment after the name
/* a block comment
   over lines */ {
	surfaceparm /* the rest of this line
	is joined to it */ nodraw
	{
		map textures/tv/c.tga // comment
		/* comment */ blendfunc add
	}
	dpglossintensitymod 3 /* comment */ // comment
}

textures/tv/swallow
{
	surfaceparm nodraw }
textures/tv/swallowed_name
{
	map textures/tv/inner.tga
}
	surfaceparm water
}

textures/tv/crlf
{
	surfaceparm water
	{
		map textures/tv/crlf.tga
		tcmod scroll 1 2
	}
	dpglossintensitymod 1.5 // comment
	surfaceparm slime
	dprtlightambient 0.5
}

textures/tv/cr{	surfaceparm lava	{		map textures/tv/cr.tga		rgbgen const 1 2 3	}	dprtlightambient 2	dpglossexponentmod 4}

textures/tv/punct
{
	{
		map textures/tv/a:b.tga
		tcmod scale (1,2)
		rgbgen wave sin;0 1
	}
	dprtlightambient [0.5]
	surfaceparm;nodraw
	surfaceparm "\n" nodraw
	dpnortlight "}"
	"{"
		map textures/tv/q.tga
	"}"
	sky ""
}

textures/tv/longparm
{
	{
		map textures/tv/0123456789012345678901234567890123456789012345678901234567890123456789012345678.tga
	}
	dp_reflectcube env/0123456789012345678901234567890123456789012345678901234567890123456789
	sky env/abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz
}

textures/tv/exact63_abcdefghijklmnopqrstuvwxyzabcdefghijklmnopq
{
	surfaceparm nodraw
}

textures/tv/exact63_abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqZ
{
	surfaceparm water
}

textures/tv/chain1233
{
	surfaceparm hint
}

textures/tv/chain828
{
	surfaceparm dust
	{
		map textures/tv/chain.tga
	}
}

TEXTURES/TV/CHAIN989
{
	surfaceparm water
}
