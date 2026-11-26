// layer keywords
textures/tv/blend_short
{
	{
		map textures/tv/a.tga
		blendfunc add
	}
	{
		map textures/tv/b.tga
		blendfunc addalpha
	}
	{
		map textures/tv/c.tga
		blendfunc filter
	}
	{
		map textures/tv/d.tga
		blendfunc BLEND
	}
	{
		map textures/tv/e.tga
		blendfunc add
		blendfunc unknownmode
	}
	{
		map textures/tv/f.tga
		blendfunc blend
		blendfunc
	}
	{
		map textures/tv/g.tga
		blendfunc GL_DST_COLOR GL_ONE extra
	}
	{ blendfunc add }
}

// more than 8 layers; the ninth and tenth are parsed into a dummy layer and dropped
textures/tv/blend_explicit
{
	{
		map textures/tv/x0.tga
		blendfunc GL_ONE GL_ZERO
	}
	{
		map textures/tv/x1.tga
		blendfunc GL_SRC_COLOR GL_ONE_MINUS_SRC_COLOR
	}
	{
		map textures/tv/x2.tga
		blendfunc GL_SRC_ALPHA GL_ONE_MINUS_SRC_ALPHA
	}
	{
		map textures/tv/x3.tga
		blendfunc GL_DST_COLOR GL_ONE_MINUS_DST_COLOR
	}
	{
		map textures/tv/x4.tga
		blendfunc GL_DST_ALPHA GL_ONE_MINUS_DST_ALPHA
	}
	{
		map textures/tv/x5.tga
		blendfunc gl_one_minus_src_alpha gl_src_alpha
	}
	{
		map textures/tv/x6.tga
		blendfunc GL_BOGUS GL_ZERO
	}
	{
		map textures/tv/x7.tga
		blendfunc GL_ZERO GL_BOGUS
	}
	{
		map $lightmap
		rgbgen vertex
	}
	{
		map textures/tv/x9.tga
		alphagen vertex
		blendfunc GL_ONE GL_ONE
	}
}

textures/tv/maps
{
	{
		clampmap textures/tv/clamp.tga
		alphafunc GE128
	}
	{
		map $LIGHTMAP
	}
	{
		animclampmap 0.5 textures/tv/x.tga textures/tv/y.tga textures/tv/z.tga
	}
	{
		animmap 3
		alphafunc
	}
	{
		map
		animmap 2 textures/tv/one.tga textures/tv/two.tga
		map textures/tv/last.tga
	}
	{
		animmap 4 textures/tv/one.tga
		map textures/tv/a:b.tga
	}
}

textures/tv/gens
{
	{
		map textures/tv/g0.tga
		rgbgen identity
		alphagen identity
		tcgen base
	}
	{
		map textures/tv/g1.tga
		rgbgen const ( 0.5 0.25 1 )
		alphagen const 0.3 0.7
	}
	{
		map textures/tv/g2.tga
		rgbGen Entity
		alphaGen Entity
		tcGen texture
	}
	{
		map textures/tv/g3.tga
		rgbgen exactvertex
		alphagen lightingspecular
		tcgen environment
	}
	{
		map textures/tv/g4.tga
		rgbgen identitylighting
		alphagen oneminusentity
		tcgen lightmap
	}
	{
		map textures/tv/g5.tga
		rgbgen lightingdiffuse
		alphagen oneminusvertex
		tcgen vector ( 1 0 0 ) ( 0 1 0 )
	}
	{
		map textures/tv/g6.tga
		rgbgen oneminusentity
		alphagen portal 256
		tcgen bogus 1 2
	}
	{
		map textures/tv/g7.tga
		rgbgen oneminusvertex
		alphagen vertex
		texgen environment
	}
}

textures/tv/waves
{
	{
		map textures/tv/w0.tga
		rgbgen vertex
		alphagen vertex
	}
	{
		map textures/tv/w1.tga
		rgbgen wave sin 0.25 0.5 0 1.5 9
		alphagen wave square 1 2 3 4
	}
	{
		map textures/tv/w2.tga
		rgbgen wave user3sin 1 2 3 4
		alphagen wave user 0 1
	}
	{
		map textures/tv/w3.tga
		rgbgen wave noise
		alphagen wave none 1
		rgbgen Wave Triangle 1
		alphagen wave user9triangle 1
	}
	{
		map textures/tv/w4.tga
		tcmod stretch sawtooth 0 1 0 1
		rgbgen wave
	}
	{
		map textures/tv/w5.tga
		rgbgen bogusgen 1 2
		alphagen bogus 3
	}
	{
		map textures/tv/w6.tga
		rgbgen wave bogusfunc 1
		alphagen wave userXsawtooth 1 2
		tcmod stretch USER2INVERSESAWTOOTH 5 6 7 8
		tcmod stretch user1 1
	}
	{
		map textures/tv/w7.tga
		tcmod scroll inversesawtooth 2
		alphagen wave
	}
}

textures/tv/tcmods
{
	{
		map textures/tv/t0.tga
		tcmod entitytranslate
		tcmod rotate 30
		tcmod scale 2 0.5
		tcmod scroll 0.1 -0.2
		tcmod page 4 2 0.5
		tcmod stretch sin 1 0.5 0 0.25
		tcmod transform 1 0 0 1 0.5 0.5 9
		tcmod turb 0 0.25 0 0.1
		tcmod scroll 9 9
	}
	{
		map textures/tv/t1.tga
		tcmod bogus 1 2 3 4 5 6
		tcmod rotate 7
		tcmod stretch
		tcmod turb sin 1 2 3 4
	}
	{
		map textures/tv/t2.tga
		tcmod
		tcmod TURB 1
		tcMod Scale -0 1e40
	}
}

// texture conversion: $lightmap as the only layer (the material layer is layers[1], past numlayers)
textures/tv/lightmap0
{
	{
		map $lightmap
	}
}

textures/tv/lightmap2
{
	{
		map textures/tv/l0.tga
		blendfunc add
	}
	{
		map textures/tv/l1.tga
	}
	{
		map $lightmap
		rgbgen identity
	}
	{
		map textures/tv/l3.tga
		blendfunc filter
	}
}

textures/tv/terrain
{
	{
		map textures/tv/rock.tga
		rgbgen identity
	}
	{
		map textures/tv/grass.tga
		blendfunc blend
		alphagen vertex
	}
	{
		map $lightmap
		blendfunc filter
	}
	{
		map textures/tv/detail.tga
		blendfunc GL_DST_COLOR GL_SRC_COLOR
	}
}

textures/tv/terrain_at
{
	{
		map textures/tv/a.tga
	}
	{
		map textures/tv/b.tga
		alphafunc GE128
		alphagen vertex
	}
	{
		map textures/tv/c.tga
		rgbgen vertex
	}
}

textures/tv/vertexlit
{
	{
		map textures/tv/a.tga
		blendfunc filter
	}
	{
		map textures/tv/b.tga
		rgbgen vertex
	}
	{
		map textures/tv/c.tga
	}
}

textures/tv/diffuse
{
	{
		map textures/tv/a.tga
	}
	{
		map textures/tv/b.tga
		rgbgen lightingdiffuse
	}
	{
		map textures/tv/spec.tga
		alphagen lightingspecular
	}
	{
		map textures/tv/d.tga
	}
}

textures/tv/effect
{
	{
		map textures/tv/fx.tga
		blendfunc GL_ONE_MINUS_DST_COLOR GL_ZERO
	}
	{
		map textures/tv/fx2.tga
	}
}

// bucket 191, where an empty name lands: a later "" shader is chained behind it
textures/tv/chainhead211
{
	surfaceparm trans
}
