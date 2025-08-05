package github

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"

	"github.com/komari-monitor/komari/utils"
	"github.com/komari-monitor/komari/utils/oauth/factory"
	"github.com/patrickmn/go-cache"
)

func (g *Github) GetName() string {
	return "github"
}
func (g *Github) GetConfiguration() factory.Configuration {
	return &g.Addition
}

func (g *Github) GetAuthorizationURL(redirectURI string) (string, string) {
	state := utils.GenerateRandomString(16)

	// 构建GitHub OAuth授权URL
	authURL := fmt.Sprintf(
		"https://github.com/login/oauth/authorize?client_id=%s&state=%s&scope=user:email&redirect_uri=%s",
		url.QueryEscape(g.Addition.ClientId),
		url.QueryEscape(state),
		url.QueryEscape(redirectURI),
	)
	g.stateCache.Set(state, true, cache.NoExpiration)
	return authURL, state
}
func (g *Github) OnCallback(ctx context.Context, state string, query map[string]string) (factory.OidcCallback, error) {
	code := query["code"]

	// 验证state防止CSRF攻击
	// state, _ := c.Cookie("oauth_state")
	if g.stateCache == nil {
		return factory.OidcCallback{}, fmt.Errorf("state cache not initialized")
	}
	if state == "" {
		return factory.OidcCallback{}, fmt.Errorf("invalid state")
	}
	// 原子性地检查并删除state，防止重复使用和竞态条件
	if _, ok := g.stateCache.Get(state); !ok {
		return factory.OidcCallback{}, fmt.Errorf("invalid state")
	}
	g.stateCache.Delete(state)

	// 获取code
	//code := c.Query("code")
	if code == "" {
		return factory.OidcCallback{}, fmt.Errorf("no code provided")
	}

	// 获取访问令牌
	tokenURL := "https://github.com/login/oauth/access_token"
	data := url.Values{
		"client_id":     {g.Addition.ClientId},
		"client_secret": {g.Addition.ClientSecret},
		"code":          {code},
	}

	req, _ := http.NewRequest("POST", tokenURL, nil)
	req.URL.RawQuery = data.Encode()
	req.Header.Set("Accept", "application/json")

	// Create HTTP client with TLS configuration to handle certificate issues
	client := &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify: false, // Keep secure by default
				MinVersion:         tls.VersionTLS12,
			},
		},
	}

	resp, err := client.Do(req)
	if err != nil {
		return factory.OidcCallback{}, fmt.Errorf("failed to get access token: %v", err)
	}
	defer resp.Body.Close()

	// 检查HTTP状态码
	if resp.StatusCode != http.StatusOK {
		return factory.OidcCallback{}, fmt.Errorf("GitHub API returned status %d", resp.StatusCode)
	}

	var tokenResp struct {
		AccessToken      string `json:"access_token"`
		TokenType        string `json:"token_type"`
		Scope            string `json:"scope"`
		Error            string `json:"error"`
		ErrorDescription string `json:"error_description"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&tokenResp); err != nil {
		return factory.OidcCallback{}, fmt.Errorf("failed to parse access token response: %v", err)
	}

	// 检查GitHub返回的错误
	if tokenResp.Error != "" {
		return factory.OidcCallback{}, fmt.Errorf("GitHub OAuth error: %s - %s", tokenResp.Error, tokenResp.ErrorDescription)
	}

	// 验证访问令牌不为空
	if tokenResp.AccessToken == "" {
		return factory.OidcCallback{}, fmt.Errorf("received empty access token from GitHub")
	}

	// 获取用户信息
	userReq, _ := http.NewRequest("GET", "https://api.github.com/user", nil)
	userReq.Header.Set("Authorization", "Bearer "+tokenResp.AccessToken)
	userReq.Header.Set("Accept", "application/json")

	userResp, err := client.Do(userReq)
	if err != nil {
		return factory.OidcCallback{}, fmt.Errorf("failed to get user info: %v", err)
	}
	defer userResp.Body.Close()

	// 检查用户信息请求的HTTP状态码
	if userResp.StatusCode != http.StatusOK {
		return factory.OidcCallback{}, fmt.Errorf("GitHub user API returned status %d", userResp.StatusCode)
	}

	var githubUser GitHubUser
	if err := json.NewDecoder(userResp.Body).Decode(&githubUser); err != nil {
		return factory.OidcCallback{}, fmt.Errorf("failed to parse user info response: %v", err)
	}

	// 验证用户ID不为空
	if githubUser.ID == 0 {
		return factory.OidcCallback{}, fmt.Errorf("received invalid user ID from GitHub")
	}

	return factory.OidcCallback{UserId: fmt.Sprintf("%d", githubUser.ID)}, nil
}
func (g *Github) Init() error {
	g.stateCache = cache.New(time.Minute*5, time.Minute*10)
	return nil
}
func (g *Github) Destroy() error {
	g.stateCache.Flush()
	return nil
}

var _ factory.IOidcProvider = (*Github)(nil)
