// services: the recipe-driven package install surface. The catalog itself is
// owned by the recipes package (embedded + root-owned overlay); these handlers
// only translate between it and the wire.
package server

import (
	"context"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	agentv1 "github.com/deploypal/agent/gen/agentv1"
	"github.com/deploypal/agent/internal/recipes"
	"github.com/deploypal/agent/internal/sysinfo"
	"github.com/deploypal/agent/internal/systemdctl"
)

func loadCatalog() (*recipes.Catalog, error) {
	cat, err := recipes.Load()
	if err != nil {
		return nil, status.Errorf(codes.Internal, "recipe catalog: %v", err)
	}
	// Everything the catalog manages becomes start/stop/restart-able from the
	// dashboard — the allow-list is derived, never maintained by hand.
	systemdctl.SetCatalogUnits(cat.Units())
	return cat, nil
}

func (s *Server) ListServiceRecipes(ctx context.Context, _ *agentv1.Empty) (*agentv1.RecipeList, error) {
	cat, err := loadCatalog()
	if err != nil {
		return nil, err
	}
	facts := recipes.HostFacts{MemTotalBytes: sysinfo.Host().MemTotal}

	firstPkgs := make([]string, 0, len(cat.Recipes))
	for _, r := range cat.Recipes {
		firstPkgs = append(firstPkgs, r.Packages[0])
	}
	versions := recipes.InstalledVersions(firstPkgs)

	out := &agentv1.RecipeList{CatalogVersion: cat.Version}
	for i := range cat.Recipes {
		r := cat.Recipes[i] // copy: Resolve mutates param defaults
		r.Resolve(facts)
		pr := &agentv1.Recipe{
			Id: r.ID, Kind: r.Kind, Name: r.Name, Description: r.Description,
			Unit: r.Unit, DefaultPort: r.DefaultPort, Packages: r.Packages,
			Source: r.Source, InstalledVersion: versions[r.Packages[0]],
			Installed: versions[r.Packages[0]] != "",
		}
		if r.Config != nil {
			pr.ConfigPath = r.Config.Path
		}
		for _, p := range r.Params {
			pr.Params = append(pr.Params, &agentv1.RecipeParam{
				Name: p.Name, Type: p.Type, Default: p.Default, Values: p.Values,
				Min: p.Min, Max: p.Max, Required: p.Required, Advanced: p.Advanced,
				DerivedHint: p.DerivedHint, UnitSuffix: p.UnitSuffix,
			})
		}
		out.Recipes = append(out.Recipes, pr)
	}
	return out, nil
}

func (s *Server) InstallService(req *agentv1.InstallServiceRequest, stream agentv1.Agent_InstallServiceServer) error {
	cat, err := loadCatalog()
	if err != nil {
		return err
	}
	recipe := cat.Get(req.RecipeId)
	if recipe == nil {
		return status.Errorf(codes.NotFound, "no recipe %q in the catalog", req.RecipeId)
	}
	emit := func(step, stepStatus, log string) {
		_ = stream.Send(&agentv1.InstallProgress{Step: step, Status: stepStatus, Log: log})
	}
	result, err := recipes.Install(stream.Context(), recipe, req.Params, emit)
	if err != nil {
		return stream.Send(&agentv1.InstallProgress{Done: true, Ok: false, Log: err.Error()})
	}
	systemdctl.SetCatalogUnits(cat.Units()) // freshly installed unit is now controllable
	return stream.Send(&agentv1.InstallProgress{
		Done: true, Ok: true, Facts: result.Facts, Secrets: result.Secrets,
	})
}

func (s *Server) RemoveService(req *agentv1.RemoveServiceRequest, stream agentv1.Agent_RemoveServiceServer) error {
	cat, err := loadCatalog()
	if err != nil {
		return err
	}
	recipe := cat.Get(req.RecipeId)
	if recipe == nil {
		return status.Errorf(codes.NotFound, "no recipe %q in the catalog", req.RecipeId)
	}
	emit := func(step, stepStatus, log string) {
		_ = stream.Send(&agentv1.InstallProgress{Step: step, Status: stepStatus, Log: log})
	}
	if err := recipes.Remove(stream.Context(), recipe, req.Purge, emit); err != nil {
		return stream.Send(&agentv1.InstallProgress{Done: true, Ok: false, Log: err.Error()})
	}
	return stream.Send(&agentv1.InstallProgress{Done: true, Ok: true})
}
