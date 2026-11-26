// fileindex 0 (first in FS_Search order). Here a "}" that ends a general parameter line ends the shader
// before that parameter is applied; in later files the "}" is swallowed.
textures/tv/first
{
	// fills all 68 parameter[] slots first, so every later stale read of parameter[] sees defined text
	{
		animmap 7.5 f00 f01 f02 f03 f04 f05 f06 f07 f08 f09 f10 f11 f12 f13 f14 f15 f16 f17 f18 f19 f20 f21 f22 f23 f24 f25 f26 f27 f28 f29 f30 f31 f32 f33 f34 f35 f36 f37 f38 f39 f40 f41 f42 f43 f44 f45 f46 f47 f48 f49 f50 f51 f52 f53 f54 f55 f56 f57 f58 f59 f60 f61 f62 f63 f64 f65 f66 f67 f68 f69
	}
	qer_editorimage textures/tv/first.tga
	surfaceparm nolightmap
}

textures/tv/closeonline
{
	surfaceparm nomarks
	surfaceparm slick }

textures/tv/afterclose
{
	{
		map textures/tv/afterclose.tga }
	dpmeshcollisions
	dpnortlight }

textures/tv/oneline { surfaceparm nodraw }

// an empty name: its bucket head is empty, and strcasecmp("", "") == 0 makes it a redeclaration (dropped)
""
{
	surfaceparm water
}

textures/tv/lastinfirst
{
	{ map textures/tv/last.tga }
	"}" surfaceparm lava
}
