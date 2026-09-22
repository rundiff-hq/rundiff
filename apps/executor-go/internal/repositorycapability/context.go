package repositorycapability

import "context"

type contextKey struct{}

func WithToken(ctx context.Context, token string) context.Context {
	if token == "" {
		return ctx
	}
	return context.WithValue(ctx, contextKey{}, token)
}

func Token(ctx context.Context) string {
	token, _ := ctx.Value(contextKey{}).(string)
	return token
}
