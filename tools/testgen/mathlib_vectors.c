#include <stdio.h>
#include <math.h>
#include <string.h>
typedef float vec_t; typedef vec_t vec3_t[3]; typedef int qboolean;
#define PITCH 0
#define YAW 1
#define ROLL 2
#define M_PI		3.14159265358979323846	// matches value in gcc v2 math.h
#define ANGLEMOD(a) ((a) - 360.0 * floor((a) / 360.0))
#define DotProduct(a,b) ((a)[0]*(b)[0]+(a)[1]*(b)[1]+(a)[2]*(b)[2])
#define VectorNormalize(v) {float ilength = (float) sqrt(DotProduct((v),(v)));if (ilength) ilength = 1.0f / ilength;(v)[0] *= ilength;(v)[1] *= ilength;(v)[2] *= ilength;}
#define VectorNormalize2(v,dest) {float ilength = (float) sqrt(DotProduct((v),(v)));if (ilength) ilength = 1.0f / ilength;dest[0] = (v)[0] * ilength;dest[1] = (v)[1] * ilength;dest[2] = (v)[2] * ilength;}
#define VectorScale(in, scale, out) ((out)[0] = (in)[0] * (scale),(out)[1] = (in)[1] * (scale),(out)[2] = (in)[2] * (scale))
#define VectorSet(vec,x,y,z) ((vec)[0]=(x),(vec)[1]=(y),(vec)[2]=(z))
void VectorVectors(const vec3_t forward, vec3_t right, vec3_t up)
{
	// NOTE: this is consistent to AngleVectors applied to AnglesFromVectors
	if (forward[0] == 0 && forward[1] == 0)
	{
		if(forward[2] > 0)
		{
			VectorSet(right, 0, -1, 0);
			VectorSet(up, -1, 0, 0);
		}
		else
		{
			VectorSet(right, 0, -1, 0);
			VectorSet(up, 1, 0, 0);
		}
	}
	else
	{
		right[0] = forward[1];
		right[1] = -forward[0];
		right[2] = 0;
		VectorNormalize(right);

		up[0] = (-forward[2]*forward[0]);
		up[1] = (-forward[2]*forward[1]);
		up[2] = (forward[0]*forward[0] + forward[1]*forward[1]);
		VectorNormalize(up);
	}
}
void AngleVectors (const vec3_t angles, vec3_t forward, vec3_t right, vec3_t up)
{
	double angle, sr, sp, sy, cr, cp, cy;

	angle = angles[YAW] * (M_PI*2 / 360);
	sy = sin(angle);
	cy = cos(angle);
	angle = angles[PITCH] * (M_PI*2 / 360);
	sp = sin(angle);
	cp = cos(angle);
	if (forward)
	{
		forward[0] = cp*cy;
		forward[1] = cp*sy;
		forward[2] = -sp;
	}
	if (right || up)
	{
		if (angles[ROLL])
		{
			angle = angles[ROLL] * (M_PI*2 / 360);
			sr = sin(angle);
			cr = cos(angle);
			if (right)
			{
				right[0] = -1*(sr*sp*cy+cr*-sy);
				right[1] = -1*(sr*sp*sy+cr*cy);
				right[2] = -1*(sr*cp);
			}
			if (up)
			{
				up[0] = (cr*sp*cy+-sr*-sy);
				up[1] = (cr*sp*sy+-sr*cy);
				up[2] = cr*cp;
			}
		}
		else
		{
			if (right)
			{
				right[0] = sy;
				right[1] = -cy;
				right[2] = 0;
			}
			if (up)
			{
				up[0] = (sp*cy);
				up[1] = (sp*sy);
				up[2] = cp;
			}
		}
	}
}
void AnglesFromVectors (vec3_t angles, const vec3_t forward, const vec3_t up, qboolean flippitch)
{
	if (forward[0] == 0 && forward[1] == 0)
	{
		if(forward[2] > 0)
		{
			angles[PITCH] = -M_PI * 0.5;
			angles[YAW] = up ? atan2(-up[1], -up[0]) : 0;
		}
		else
		{
			angles[PITCH] = M_PI * 0.5;
			angles[YAW] = up ? atan2(up[1], up[0]) : 0;
		}
		angles[ROLL] = 0;
	}
	else
	{
		angles[YAW] = atan2(forward[1], forward[0]);
		angles[PITCH] = -atan2(forward[2], sqrt(forward[0]*forward[0] + forward[1]*forward[1]));
		// note: we know that angles[PITCH] is in ]-pi/2..pi/2[ due to atan2(anything, positive)
		if (up)
		{
			vec_t cp = cos(angles[PITCH]), sp = sin(angles[PITCH]);
			// note: we know cp > 0, due to the range angles[pitch] is in
			vec_t cy = cos(angles[YAW]), sy = sin(angles[YAW]);
			vec3_t tleft, tup;
			tleft[0] = -sy;
			tleft[1] = cy;
			tleft[2] = 0;
			tup[0] = sp*cy;
			tup[1] = sp*sy;
			tup[2] = cp;
			angles[ROLL] = -atan2(DotProduct(up, tleft), DotProduct(up, tup));
			// for up == '0 0 1', this is
			// angles[ROLL] = -atan2(0, cp);
			// which is 0
		}
		else
			angles[ROLL] = 0;

		// so no up vector is equivalent to '1 0 0'!
	}

	// now convert radians to degrees, and make all values positive
	VectorScale(angles, 180.0 / M_PI, angles);
	if (flippitch)
		angles[PITCH] *= -1;
	if (angles[PITCH] < 0) angles[PITCH] += 360;
	if (angles[YAW] < 0) angles[YAW] += 360;
	if (angles[ROLL] < 0) angles[ROLL] += 360;

}
static void pv(const vec3_t v) { unsigned u[3]; memcpy(u, v, 12); printf("\t%08x %08x %08x", u[0], u[1], u[2]); }
int main(void) {
	float in[][3] = {{0,0,0},{90,0,0},{-45,30,0},{10,200,15},{0.5f,-720.25f,90},{33.3f,123.4f,-56.7f},{89.9f,359.9f,1},{-90,45,180},{1e-3f,1e3f,1e-3f},{12,34,56}};
	for (unsigned k = 0; k < sizeof in / sizeof *in; k++) {
		vec3_t a, f, r, u, b, r2, u2, n;
		memcpy(a, in[k], 12);
		AngleVectors(a, f, r, u);
		printf("AV"); pv(a); pv(f); pv(r); pv(u); printf("\n");
		AnglesFromVectors(b, f, u, 1); printf("AFV"); pv(f); pv(u); pv(b); printf("\n");
		AnglesFromVectors(b, a, NULL, 0); printf("AFV0"); pv(a); pv(b); printf("\n");
		VectorNormalize2(a, n); printf("N2"); pv(a); pv(n); printf("\n");
		VectorVectors(n, r2, u2); printf("VV"); pv(n); pv(r2); pv(u2); printf("\n");
	}
	return 0;
}
