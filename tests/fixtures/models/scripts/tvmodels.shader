// shaders the fixture models use
models/tv/skin_b
{
	{
		map models/tv/skin_b.tga
		blendfunc add
	}
}
tvshader/red
{
	surfaceparm nonsolid
	{
		map $whiteimage
		rgbgen lightingdiffuse
	}
}
tvshader/blue
{
	cull none
	{
		map models/tv/blue.tga
		alphafunc GE128
	}
}
